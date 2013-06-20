# require 'resque/tasks'
# will give you the resque tasks

namespace :resque do
  task :setup

  desc "Start a Resque worker"
  task :master => [ :preload, :setup ] do
    require 'resque'
    require 'topdog'

    queues = (ENV['QUEUES'] || ENV['QUEUE']).to_s.split(',')
    num_workers = (ENV['WORKERS'] || 1).to_i

    verbose = !!(ENV['LOGGING'] || ENV['VERBOSE'])
    very_verbose = !!ENV['VVERBOSE']

    interval = (ENV['INTERVAL'] || 5).to_f
    maximum_task_time = (ENV['MAX_TASK_TIME'] || 10).to_f

    # Resque validates queues inside of the worker class as well, but we need
    # to do it here as well. If we don't, each worker will throw an exception
    # on startup and the master will spin, forking workers forever.
    if queues.nil? || queues.empty?
      abort "set QUEUE env var, e.g. $ QUEUE=critical,high rake resque:work"
    end

    if ENV['PIDFILE']
      File.open(ENV['PIDFILE'], 'w') { |f| f << Process.pid }
    end

    wait_sleep = 0.10   # Interval to wait between polling on #wait
    buffer_time = 2     # Grace period for supervisor timeouts

    # This is how often a worker can be expected to check in. Within the outer
    # job dequeuing loop, the duration is on the order of interval, however, in
    # the process wait loop, the duration is the wait_sleep. Also, choose a
    # minimum of two seconds so that the master isn't constantly waking up.
    checkin_interval = [interval, wait_sleep, 2].max

    topdog_options = {
      :name => 'resque',
      :num_workers => num_workers,
      :log_status => very_verbose,

      # If the master process needs to go down, it will signal the workers to
      # terminate but leave them running for at most :shutdown_timeout
      # seconds. They will commit suicide once that interval has elapsed.
      :synchonous_shutdown => false,

      # Set sensible, generous defaults
      :timeout => checkin_interval + buffer_time,
      :shutdown_timeout => maximum_task_time + buffer_time,
      :startup_timeout => 10
    }

    worker_options = {
      :queues => queues,

      :interval => interval,
      :maximum_task_time => maximum_task_time,
      :wait_sleep => wait_sleep,

      :verbose => verbose,
      :very_verbose => very_verbose
    }

    Topdog.run!(topdog_options) do |master|
      worker = Resque::Worker.new(
        worker_options.merge(:master => master))

      worker.log "Starting worker #{worker}"
      worker.work
    end

  end

  # Original tasks...

  desc "Start a Resque worker"
  task :work => [ :preload, :setup ] do
    require 'resque'

    queues = (ENV['QUEUES'] || ENV['QUEUE']).to_s.split(',')
    interval = (ENV['INTERVAL'] || 5).to_f

    verbose = !!(ENV['LOGGING'] || ENV['VERBOSE'])
    very_verbose = !!ENV['VVERBOSE']

    worker_options = {
      :queues => queues,
      :interval => interval,

      :verbose => verbose,
      :very_verbose => very_verbose
    }

    begin
      worker = Resque::Worker.new(worker_options)
    rescue Resque::NoQueueError
      abort "set QUEUE env var, e.g. $ QUEUE=critical,high rake resque:work"
    end

    if ENV['BACKGROUND']
      unless Process.respond_to?('daemon')
          abort "env var BACKGROUND is set, which requires ruby >= 1.9"
      end
      Process.daemon(true)
    end

    if ENV['PIDFILE']
      File.open(ENV['PIDFILE'], 'w') { |f| f << worker.pid }
    end

    worker.log "Starting worker #{worker}"
    worker.work # will block
  end

  desc "Start multiple Resque workers. Should only be used in dev mode."
  task :workers do
    threads = []

    ENV['COUNT'].to_i.times do
      threads << Thread.new do
        system "rake resque:work"
      end
    end

    threads.each { |thread| thread.join }
  end

  # Preload app files if this is Rails
  task :preload => :setup do
    if defined?(Rails) && Rails.respond_to?(:application)
      # Rails 3
      Rails.application.eager_load!
    elsif defined?(Rails::Initializer)
      # Rails 2.3
      $rails_rake_task = false
      Rails::Initializer.run :load_application_classes
    end
  end
end
