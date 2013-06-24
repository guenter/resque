module Resque
  # A Resque Worker processes jobs. On platforms that support fork(2),
  # the worker will fork off a child to process each job. This ensures
  # a clean slate when beginning the next job and cuts down on gradual
  # memory growth as well as low level failures.
  #
  # It also ensures workers are always listening to signals from you,
  # their master, and can react accordingly.
  class Worker
    include Resque::Helpers
    extend Resque::Helpers

    attr_accessor :master
    attr_accessor :queues

    # Whether the worker should log basic info to STDOUT
    attr_accessor :verbose

    # Whether the worker should log lots of info to STDOUT
    attr_accessor  :very_verbose

    # Boolean indicating whether this worker can or can not fork.
    # Automatically set if a fork(2) fails.
    attr_accessor :cant_fork

    attr_writer :to_s

    # Returns an array of all worker objects.
    def self.all
      Array(redis.smembers(:workers)).map { |id| find(id) }.compact
    end

    # Returns an array of all worker objects currently processing
    # jobs.
    def self.working
      names = all
      return [] unless names.any?

      names.map! { |name| "worker:#{name}" }

      reportedly_working = {}

      begin
        reportedly_working = redis.mapped_mget(*names).reject do |key, value|
          value.nil? || value.empty?
        end
      rescue Redis::Distributed::CannotDistribute
        names.each do |name|
          value = redis.get name
          reportedly_working[name] = value unless value.nil? || value.empty?
        end
      end

      reportedly_working.keys.map do |key|
        find key.sub("worker:", '')
      end.compact
    end

    # Returns a single worker object. Accepts a string id.
    def self.find(worker_id)
      if exists? worker_id
        queues = worker_id.split(':')[-1].split(',')
        worker = new(:queues => queues)
        worker.to_s = worker_id
        worker
      else
        nil
      end
    end

    # Alias of `find`
    def self.attach(worker_id)
      find(worker_id)
    end

    # Given a string worker id, return a boolean indicating whether the
    # worker exists
    def self.exists?(worker_id)
      redis.sismember(:workers, worker_id)
    end

    # Workers should be initialized with an array of string queue
    # names. The order is important: a Worker will check the first
    # queue given for a job. If none is found, it will check the
    # second queue name given. If a job is found, it will be
    # processed. Upon completion, the Worker will again check the
    # first queue given, and so forth. In this way the queue list
    # passed to a Worker on startup defines the priorities of queues.
    #
    # If passed a single "*", this Worker will operate on all queues
    # in alphabetical order. Queues can be dynamically added or
    # removed without needing to restart workers using this method.
    def initialize(options={})
      @options = options

      @master = @options[:master]
      @queues = @options[:queues].map { |queue| queue.to_s.strip }

      @interval = @options[:interval] || 5
      @maximum_task_time = @options[:maximum_task_time]
      @wait_sleep = @options[:wait_sleep] || 0.1

      validate_queues
    end

    # A worker must be given a queue, otherwise it won't know what to
    # do with itself.
    #
    # You probably never need to call this.
    def validate_queues
      if @queues.nil? || @queues.empty?
        raise NoQueueError.new("Please give each worker at least one queue.")
      end
    end

    # This is the main workhorse method. Called on a Worker instance,
    # it begins the worker life cycle.
    #
    # The following events occur during a worker's life cycle:
    #
    # 1. Startup:   Signals are registered, dead workers are pruned,
    #               and this worker is registered.
    # 2. Work loop: Jobs are pulled from a queue and processed.
    # 3. Teardown:  This worker is unregistered.
    #
    # Can be passed a float representing the polling frequency.
    # The default is 5 seconds, but for a semi-active site you may
    # want to use a smaller value.
    #
    # Also accepts a block which will be passed the job as soon as it
    # has completed processing. Useful for testing.
    def work(&block)
      update_status "resque: Starting"
      startup

      # The pattern of "either no master or #wants_me_alive?" is used to
      # support the transitional case in which we want to preserve the
      # behavior of resque without a process supervisor.

      until wants_down?

        if (job = reserve)
          log "got: #{job.inspect}"
          run_hook :before_fork, job
          working_on job

          start_time = Time.now
          limit = start_time + @maximum_task_time if @maximum_task_time

          # Fork the child process!

          @child = Kernel.fork do
            srand # Reseeding
            untrap_signals
            start_task_timer(job)
            procline "Processing #{job.queue} since #{Time.now.to_i}"
            perform(job, &block)
            exit!
          end

          srand # Reseeding
          procline "Forked #{@child} at #{Time.now.to_i}"

          # Wait until the child dies (or the timeout is exceeded)!

          begin
            until wants_down?
              # Once we receive notifcation that one of our children has died,
              # our work is done. Move on to the next task.
              break if Process.wait(-1, Process::WNOHANG)

              # If the client specified a maximum time limit for tasks, enforce
              # it here by sending the kill signal. Even though this case should
              # be covered by child auto-termination, we give the worker another
              # way out as an affordance against the possibilty of perpetually
              # waiting for its child to terminate.
              if limit && Time.now > limit
                log_always "killed job (ran for #{Time.now - start_time}s)"

                begin
                  Process.kill(:KILL, @child)
                rescue Errno::ESRCH
                end
                # Mark the job as failed and notify redis for stats
                job.fail(ExceededTimeout.new)
                failed!
                break
              end

              # Sleep between polls
              sleep @wait_sleep
            end
          rescue Errno::EINTR
            retry
          # These can be thrown by Process.wait, they indicate to us that our
          # child is no longer running (or died before the loop started).
          rescue Errno::ECHILD, Errno::ESRCH
          end

          # Report that we're done!

          done_working
          @child = nil
        else
          log! "Sleeping for #{@interval} seconds"
          procline "Waiting for #{@queues.join(',')}"
          sleep @interval
        end
      end

    ensure
      unregister_worker
    end

    def wants_down?
      shutdown? || (master && !master.wants_me_alive?)
    end

    # DEPRECATED. Processes a single job. If none is given, it will
    # try to produce one. Usually run in the child.
    def process(job = nil, &block)
      return unless job ||= reserve

      working_on job
      perform(job, &block)
    ensure
      done_working
    end

    # Processes a given job in the child.
    def perform(job)
      begin
        run_hook :after_fork, job
        job.perform
      rescue Object => e
        log "#{job.inspect} failed: #{e.inspect}"
        begin
          job.fail(e)
        rescue Object => e
          log "Received exception when reporting failure: #{e.inspect}"
        end
        failed!
      else
        log "done: #{job.inspect}"
      ensure
        yield job if block_given?
      end
    end

    # Runs within the child process, forces termination when the maximum
    # job length is exceeded.
    def start_task_timer(job)
      return unless @maximum_task_time
      start_time = Time.now
      Thread.new do
        sleep @maximum_task_time
        # Mark the job as failed and notify redis for stats
        log_always "killed job (ran for #{Time.now - start_time}s)"
        job.fail(ExceededTimeout.new)
        failed!
        exit!
      end
    end

    def untrap_signals
      master.untrap_signals if master
    end

    # Attempts to grab a job off one of the provided queues. Returns
    # nil if no job can be found.
    def reserve
      queues.each do |queue|
        log! "Checking #{queue}"
        if job = Resque.reserve(queue)
          log! "Found job on #{queue}"
          return job
        end
      end

      nil
    rescue Exception => e
      log "Error reserving job: #{e.inspect}"
      log e.backtrace.join("\n")
      raise e
    end

    # Returns a list of queues to use when searching for a job.
    # A splat ("*") means you want every queue (in alpha order) - this
    # can be useful for dynamically adding new queues.
    def queues
      @queues[0] == "*" ? Resque.queues.sort : @queues
    end

    # Runs all the methods needed when a worker begins its lifecycle.
    def startup
      enable_gc_optimizations
      # If we're being supervised, the master informs us of our termination
      # through a different mechanism.
      register_signal_handlers unless master
      prune_dead_workers
      run_hook :before_first_fork
      register_worker

      # Fix buffering so we can `rake resque:work > resque.log` and
      # get output from the child in there.
      $stdout.sync = true
    end

    # Enables GC Optimizations if you're running REE.
    # http://www.rubyenterpriseedition.com/faq.html#adapt_apps_for_cow
    def enable_gc_optimizations
      if GC.respond_to?(:copy_on_write_friendly=)
        GC.copy_on_write_friendly = true
      end
    end

    # Registers the various signal handlers a worker responds to.
    # TERM: Shutdown immediately, stop processing jobs.
    #  INT: Shutdown immediately, stop processing jobs.
    # QUIT: Shutdown after the current job has finished processing.
    def register_signal_handlers
      trap('TERM') { shutdown! }
      trap('INT')  { shutdown! }
      trap('QUIT') { shutdown  }

      log! "Registered signals"
    end

    # Schedule this worker for shutdown. Will finish processing the
    # current job.
    def shutdown
      log 'Exiting...'
      @shutdown = true
    end

    # Kill the child and shutdown immediately.
    def shutdown!
      shutdown
      kill_child
    end

    # Should this worker shutdown as soon as current job is finished?
    def shutdown?
      @shutdown
    end

    # Kills the forked child immediately, without remorse. The job it
    # is processing will not be completed.
    def kill_child
      Process.kill("KILL", @child) if @child
    rescue Errno::ESRCH
    end

    # Looks for any workers which should be running on this server
    # and, if they're not, removes them from Redis.
    #
    # This is a form of garbage collection. If a server is killed by a
    # hard shutdown, power failure, or something else beyond our
    # control, the Resque workers will not die gracefully and therefore
    # will leave stale state information in Redis.
    #
    # By checking the current Redis state against the actual
    # environment, we can determine if Redis is old and clean it up a bit.
    def prune_dead_workers
      all_workers = Worker.all
      known_workers = worker_pids unless all_workers.empty?
      all_workers.each do |worker|
        host, pid, queues = worker.id.split(':')
        next unless host == hostname
        next if known_workers.include?(pid)
        log! "Pruning dead worker: #{worker}"
        worker.unregister_worker
      end
    end

    # Registers ourself as a worker. Useful when entering the worker
    # lifecycle on startup.
    def register_worker
      redis.sadd(:workers, self)
      started!
    end

    # Runs a named hook, passing along any arguments.
    def run_hook(name, *args)
      return unless hook = Resque.send(name)
      msg = "Running #{name} hook"
      msg << " with #{args.inspect}" if args.any?
      log msg

      args.any? ? hook.call(*args) : hook.call
    end

    # Unregisters ourself as a worker. Useful when shutting down.
    def unregister_worker
      # If we're still processing a job, make sure it gets logged as a
      # failure.
      if (hash = processing) && !hash.empty?
        job = Job.new(hash['queue'], hash['payload'])
        # Ensure the proper worker is attached to this job, even if
        # it's not the precise instance that died.
        job.worker = self
        job.fail(DirtyExit.new)
      end

      redis.srem(:workers, self)
      redis.del("worker:#{self}")
      redis.del("worker:#{self}:started")

      Stat.clear("processed:#{self}")
      Stat.clear("failed:#{self}")
    end

    # Given a job, tells Redis we're working on it. Useful for seeing
    # what workers are doing and when.
    def working_on(job)
      job.worker = self
      data = encode \
        :queue   => job.queue,
        :run_at  => Time.now.strftime("%Y/%m/%d %H:%M:%S %Z"),
        :payload => job.payload
      redis.set("worker:#{self}", data)
    end

    # Called when we are done working - clears our `working_on` state
    # and tells Redis we processed a job.
    def done_working
      processed!
      redis.del("worker:#{self}")
    end

    # How many jobs has this worker processed? Returns an int.
    def processed
      Stat["processed:#{self}"]
    end

    # Tell Redis we've processed a job.
    def processed!
      Stat << "processed"
      Stat << "processed:#{self}"
    end

    # How many failed jobs has this worker seen? Returns an int.
    def failed
      Stat["failed:#{self}"]
    end

    # Tells Redis we've failed a job.
    def failed!
      Stat << "failed"
      Stat << "failed:#{self}"
    end

    # What time did this worker start? Returns an instance of `Time`
    def started
      redis.get "worker:#{self}:started"
    end

    # Tell Redis we've started
    def started!
      redis.set("worker:#{self}:started", Time.now.to_s)
    end

    # Returns a hash explaining the Job we're currently processing, if any.
    def job
      decode(redis.get("worker:#{self}")) || {}
    end
    alias_method :processing, :job

    # Boolean - true if working, false if not
    def working?
      state == :working
    end

    # Boolean - true if idle, false if not
    def idle?
      state == :idle
    end

    # Returns a symbol representing the current worker state,
    # which can be either :working or :idle
    def state
      redis.exists("worker:#{self}") ? :working : :idle
    end

    # Is this worker the same as another worker?
    def ==(other)
      to_s == other.to_s
    end

    def inspect
      "#<Worker #{to_s}>"
    end

    # The string representation is the same as the id for this worker
    # instance. Can be used with `Worker.find`.
    def to_s
      @to_s ||= "#{hostname}:#{Process.pid}:#{@queues.join(',')}"
    end
    alias_method :id, :to_s

    # chomp'd hostname of this machine
    def hostname
      @hostname ||= `hostname`.chomp
    end

    # Returns Integer PID of running worker
    def pid
      Process.pid
    end

    # Returns an Array of string pids of all the other workers on this
    # machine. Useful when pruning dead workers on startup.
    def worker_pids
      if RUBY_PLATFORM =~ /solaris/
        solaris_worker_pids
      else
        linux_worker_pids
      end
    end

    # Find Resque worker pids on Linux and OS X.
    #
    # Returns an Array of string pids of all the other workers on this
    # machine. Useful when pruning dead workers on startup.
    def linux_worker_pids
      `ps -A -o pid,command | grep "[r]esque" | grep -v "resque-web"`.split("\n").map do |line|
        line.split(' ')[0]
      end
    end

    # Find Resque worker pids on Solaris.
    #
    # Returns an Array of string pids of all the other workers on this
    # machine. Useful when pruning dead workers on startup.
    def solaris_worker_pids
      `ps -A -o pid,comm | grep "[r]uby" | grep -v "resque-web"`.split("\n").map do |line|
        real_pid = line.split(' ')[0]
        pargs_command = `pargs -a #{real_pid} 2>/dev/null | grep [r]esque | grep -v "resque-web"`
        if pargs_command.split(':')[1] == " resque-#{Resque::Version}"
          real_pid
        end
      end.compact
    end

    # Given a string, sets the procline ($0) and logs.
    # Procline is always in the format of:
    #   resque-VERSION: STRING
    def procline(string)
      update_status "resque-#{Resque::Version}: #{string}"
    end

    def log_always(message)
      to_output "*** #{message}"
    end

    # Log a message to STDOUT if we are verbose or very_verbose.
    def log(message)
      if verbose
        to_output "*** #{message}"
      elsif very_verbose
        time = Time.now.strftime('%H:%M:%S %Y-%m-%d')
        to_output "** [#{time}] #$$: #{message}"
      end
    end

    # Logs a very verbose message to STDOUT.
    def log!(message)
      log message if very_verbose
    end

    def to_output(string)
      master ? master.logger.info(string) : puts(string)
    end

    def update_status(string)
      master ? master.update_status(string) : ($0 = string)
    end

  end
end
