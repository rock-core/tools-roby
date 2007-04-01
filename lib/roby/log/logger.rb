require 'roby/log/hooks'

module Roby::Log
    @loggers = Array.new
    @@logging_thread = nil

    extend Logger::Hierarchy
    extend Logger::Forward

    class << self
	# Start the logging framework
	def logging?; @@logging_thread end

	# Start the logging framework
	def start_logging # :nodoc:
	    return if logging?
	    logged_events.clear
	    @@logging_thread = Thread.new(&method(:logger_loop))
	end

	# Stop the logging framework
	def stop_logging # :nodoc:
	    return unless logging?
	    logged_events.push nil
	    @@logging_thread.join
	    @@logging_thread = nil
	end

	# Add a logger object in the system
	def add_logger(logger)
	    start_logging
	    @loggers << logger
	end

	# Remove a logger from the list of loggers
	def remove_logger(logger)
	    flush if logging?
	    if @loggers.size == 1
		stop_logging
	    end
	    @loggers.delete logger
	end

	# Remove all loggers
	def clear_loggers
	    stop_logging
	    @loggers.clear
	end

	# Iterates on all the logger objects. If +m+ is given, yields only the loggers
	# which respond to this method.
	def each_logger(m = nil)
	    @loggers.each do |log|
		yield(log) if !m || log.respond_to?(m)
	    end
	end

	# Returns true if there is at least one loggr for the +m+ message
	def has_logger?(m); @loggers.any? { |log| log.respond_to?(m) } end

	LOGGED_EVENTS_QUEUE_SIZE = 2000
	attribute(:logged_events) { SizedQueue.new(LOGGED_EVENTS_QUEUE_SIZE) }

	attribute(:flushed_logger_mutex) { Mutex.new }
	attribute(:flushed_logger) { ConditionVariable.new }

	attribute(:known_objects) { ValueSet.new }

	def incremental_dump?(object); known_objects.include?(object) end

	# call-seq:
	#   Log.log(message) { args }
	#
	# Logs +message+ with argument +args+. The block is called only once if
	# there is at least one logger which listens for +message+.
	def log(m, args = nil)
	    if m == :discovered_tasks || m == :discovered_events
		Roby::Control.synchronize do
		    args ||= yield
		    objects = args[2].to_value_set
		    # Do not give a 'peer' argument at Distributed.format, to
		    # make sure we do a full dump
		    args = Roby::Distributed.format(args) if has_logger?(m)
		    known_objects.merge(objects)
		end
	    elsif m == :finalized_task || m == :finalized_event
		Roby::Control.synchronize do
		    args ||= yield
		    object = args[2]
		    args = Roby::Distributed.format(args, self) if has_logger?(m)
		    known_objects.delete(object)
		end
	    end

	    if has_logger?(m)
		if !args && block_given?
		    Roby::Control.synchronize do 
			args = Roby::Distributed.format(yield, self)
		    end
		end

		logged_events << [m, args]
	    end
	end

	# The main logging loop. We use a separate loop to avoid having logging
	# have too much influence on the control thread. The Log.logged_events
	# attribute is a sized queue (of size LOGGED_EVENTS_QUEUE_SIZE) in
	# which all the events needing logging are saved
	def logger_loop
	    Thread.current.priority = 2
	    loop do
		m, args = logged_events.pop
		break unless m

		each_logger(m) do |logger|
		    if logger.splat?
			logger.send(m, *args)
		    else
			logger.send(m, args)
		    end
		end

		if m == :flush
		    flushed_logger_mutex.synchronize do
			flushed_logger.signal
		    end
		end
	    end

	ensure
	    # Wake up any waiting thread
	    flushed_logger_mutex.synchronize do
		flushed_logger.signal
	    end
	end

	# Waits for all the events queued in +logged_events+ to be processed by
	# the logging thread. Also sends the +flush+ message to all loggers
	# that respond to it
	def flush
	    flushed_logger_mutex.synchronize do
		if !logging?
		    raise "not logging"
		end

		logged_events.push [:flush, []]
		flushed_logger.wait(flushed_logger_mutex)
	    end
	end

	# Requires all displays
	def load_all_displays
	    require 'roby/log/relations'
	    require 'roby/log/execution-state'
	end

	def open(file)
	    if file =~ /\.gz$/
		require 'zlib'
		require 'roby/log/file'
		Zlib::GzipReader.open(file)
	    elsif file =~ /\.db$/
		raise NotImplementedError
	    else
		require 'roby/log/file'
		File.open(file)
	    end
	end

	def replay(file, &block)
	    if file =~ /\.gz$/
		require 'zlib'
		require 'roby/log/file'
		Zlib::GzipReader.open(file) do |io|
		    FileLogger.replay(io, &block)
		end
	    elsif file =~ /\.db$/
		require 'roby/log/sqlite'
		SQLiteLogger.replay(file, &block)
	    else
		require 'roby/log/file'
		File.open(file) do |io|
		    FileLogger.replay(io, &block)
		end
	    end
	end
    end
end

