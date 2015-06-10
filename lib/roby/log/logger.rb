require 'utilrb/logger'
require 'roby/log/hooks'
require 'roby/log/file'

module Roby::Log
    @loggers = Array.new
    @@logging_thread = nil

    extend Logger::Hierarchy
    extend Logger::Forward

    class << self
	# Start the logging framework
	def logging?
	    @@logging_thread
	end

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
	    flushed_logger_mutex.synchronize do
		while @@logging_thread
		    flushed_logger.wait(flushed_logger_mutex)
		end
	    end
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
            logger.close
	end

	# Remove all loggers
	def clear_loggers
	    stop_logging
	    @loggers.clear
	end

	# Iterates on all the logger objects. If +m+ is given, yields only the loggers
	# which respond to this method.
	def each_logger(m = nil)
	    for l in @loggers
		if !m || l.respond_to?(m)
		    yield(l) 
		end
	    end
	end

	# Returns true if there is at least one loggr for the +m+ message
	def has_logger?(m)
	    return if !logging?
	    for l in @loggers
		return true if l.logs_message?(m)
	    end
	    false
	end

	attr_reader :logged_events
	attr_reader :flushed_logger_mutex
	attr_reader :flushed_logger
	attr_reader :known_objects

	def incremental_dump?(object); known_objects.include?(object) end

	# call-seq:
	#   Log.log(message) { args }
	#
	# Logs +message+ with argument +args+. The block is called only once if
	# there is at least one logger which listens for +message+.
	def log(m, args = nil)
	    if m == :added_tasks || m == :added_events
		Roby.synchronize do
		    args ||= yield
		    objects = args[1].to_value_set
		    # Do not give a 'peer' argument at Distributed.format, to
		    # make sure we do a full dump
		    args = Roby::Distributed.format(args) if has_logger?(m)
		    known_objects.merge(objects)
		end
	    elsif m == :finalized_task || m == :finalized_event
		Roby.synchronize do
		    args ||= yield
		    object = args[1]
		    args = Roby::Distributed.format(args, self) if has_logger?(m)
		    known_objects.delete(object)
		end
	    end

	    if has_logger?(m)
		if !args && block_given?
		    Roby.synchronize do 
			args = Roby::Distributed.format(yield, self)
		    end
		end

		logged_events << [m, Time.now, args]
	    end
	end

	# The main logging loop. We use a separate loop to avoid having logging
	# have too much influence on the control thread. The Log.logged_events
	# attribute is a sized queue (of size LOGGED_EVENTS_QUEUE_SIZE) in
	# which all the events needing logging are saved
	def logger_loop
	    Thread.current.priority = 2
	    loop do
		m, time, args = logged_events.pop
		break unless m

		each_logger(m) do |logger|
		    if logger.splat?
			logger.send(m, time, *args)
		    else
			logger.send(m, time, args)
		    end
		end

		if m == :flush && logged_events.empty?
		    flushed_logger_mutex.synchronize do
			flushed_logger.broadcast
		    end
		    logged_events.clear
		end
	    end

	rescue Exception => e
	    Roby::Log.fatal "logger thread dies with #{e.full_message}" unless e.kind_of?(Interrupt)

	ensure
	    # Wake up any waiting thread
	    flushed_logger_mutex.synchronize do
		@@logging_thread = nil
		flushed_logger.broadcast
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
	    Logfile.open(file)
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

    LOGGED_EVENTS_QUEUE_SIZE = 2000
    @logged_events        = SizedQueue.new(LOGGED_EVENTS_QUEUE_SIZE)
    @flushed_logger_mutex = Mutex.new
    @flushed_logger       = ConditionVariable.new
    @known_objects        = ValueSet.new

end

