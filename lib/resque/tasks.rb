# require 'resque/tasks'
# will give you the resque tasks

namespace :resque do
  task :setup

  desc "Start a Resque worker"
  task :work => [ :preload, :setup ] do
    require 'resque'
    require 'topdog'

    queues = (ENV['QUEUES'] || ENV['QUEUE']).to_s.split(',')
    num_workers = (ENV['WORKERS'] || 1).to_i

    verbose = ENV['LOGGING'] || ENV['VERBOSE']
    very_verbose = ENV['VVERBOSE']

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

    # We expect the worker's checkins to be as seperated as the largest delay
    checkin_interval = [maximum_task_time, interval].max

    topdog_options = {
      :name => 'Resque',
      :num_workers => num_workers,
      :leave_workers_running => true,
      :log_status => very_verbose,

      # Set sensible, generous defaults
      :timeout => 2 * checkin_interval,
      :shutdown_timeout => checkin_interval,
      :startup_timeout => 30
    }

    worker_options = {
      :queues => queues,
      :interval => interval,
      :maximum_task_time => maximum_task_time
    }

    Topdog.run!(topdog_options) do |master|
      worker = Resque::Worker.new(master, worker_options)
      worker.verbose = verbose
      worker.very_verbose = very_verbose
      worker.work
    end

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
