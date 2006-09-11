require 'roby/log/hooks'

module Roby::Log
    @loggers = Array.new
    class << self
	# All logger objects in the system
	attr_reader :loggers

	# Iterates on all the logger objects. If +m+ is given, yields only the loggers
	# which respond to this method.
	def each_logger(m = nil)
	    @loggers.each do |log|
		yield(log) if !m || log.respond_to?(m)
	    end
	end

	# Returns true if there is at least one loggr for the +m+ message
	def has_logger?(m); loggers.any? { |log| log.respond_to?(m) } end

	# call-seq:
	#   Log.log(message) { args }
	#
	# Logs +message+ with argument +args+. The block is called only once if
	# there is at least one logger which listens for +message+.
	def log(m, args = nil)
	    if has_logger?(m)
		args = yield if block_given?
	        each_logger(m) do |log|
		    log.send(m, *args)
		end
	    end
	end

	def flush
	    each_logger(:flush) do |log|
		log.flush
	    end
	end

	# Requires all displays
	def load_all_displays
	    require 'roby/log/relations'
	    require 'roby/log/execution-state'
	end
    end

    # A logger object which marshals events in a IO object. The log files can
    # be replayed (for off-line display) by calling FileLogger.replay(io)
    class FileLogger
	@dumped = Hash.new
	class << self
	    attr_reader :dumped
	end

	attr_reader :io
	def initialize(io)
	    @io = io
	end

	[:generator_calling, :generator_fired, :generator_signalling, 
	 :task_initialize].each do |m|
	    @dumped[m] = Marshal.dump(m)
	    define_method(m) { |*args| io << FileLogger.dumped[m] << Marshal.dump(args) }
	end
	[:added_task_relation, :added_event_relation].each do |m|
	    @dumped[m] = Marshal.dump(m)
	    define_method(m) do |time, type, from, to, info|
		io << FileLogger.dumped[m] << 
		    Marshal.dump([time, type.name, from, to, info.to_s])
	    end
	end
	[:removed_task_relation, :removed_event_relation].each do |m|
	    @dumped[m] = Marshal.dump(m)
	    define_method(m) do |time, type, from, to|
		io << FileLogger.dumped[m] << 
		    Marshal.dump([time, type.name, from, to])
	    end
	end

	def self.replay(io)
	    loop do
		method_name = Marshal.load(io)
		method_args = Marshal.load(io)
		if method_name.to_s =~ /_relation$/
		    method_args[1] = Module.constant(method_args[1])
		end

		Log.log(method_name, method_args)
	    end
	rescue EOFError
	ensure
	    Log.flush
	end
    end

    # A logger object which dumps events in a human-readable form to an IO object. 
    class ConsoleLogger
	def self.filter_names(name)
	    name.gsub(/Roby::(?:Genom::)?/, '')
	end
	# Name of an event generator source
	def self.gen_source(gen)
	    if gen.respond_to?(:task) then gen.task.name
	    else 'toplevel'
	    end
	end
	# Human readable name for event generators
	def self.gen_name(gen)
	    if gen.respond_to?(:symbol) then "[#{gen.symbol}]"
	    else gen.name
	    end
	end
	
	attr_reader :io, :columns
	def initialize(io)
	    @io = io
	    @columns = Array.new
	end

	def display(time, *args) # :nodoc:
	    @reftime ||= time

	    if @last_ref == args[0, 2]
		args[0, 2] = ["", ""]
	    else
		@last_ref = args[0, 2]
	    end

	    args.unshift(Time.at(time - @reftime).to_hms)
	    args = args.map(&ConsoleLogger.method(:filter_names))
	    args.each_with_index do |str, i|
		if !columns[i] || (str.length > columns[i])
		    columns[i] = str.length
		end
	    end

	    args.each_with_index do |arg, i|
		w = columns[i]
		io << ("%-#{w}s  " % arg)
	    end
	    io << "\n"
	end
	private :display

	def generator_calling(time, gen, context) # :nodoc:
	    display(time, ConsoleLogger.gen_source(gen), ConsoleLogger.gen_name(gen), "call", "ctxt=#{context.inspect}")
	end
	def generator_fired(time, event) # :nodoc:
	    display(time, ConsoleLogger.gen_source(event.generator), 
		    ConsoleLogger.gen_name(event.generator), "fired", 
		    "#{ConsoleLogger.gen_name(event)}!#{event.source_address.to_s(16)} ctxt=#{event.context.inspect}")
	end
	def generator_signalling(time, event, generator) # :nodoc:
	    display(time, ConsoleLogger.gen_source(event.generator), 
		    ConsoleLogger.gen_name(event.generator), "signal", 
		    "#{ConsoleLogger.gen_name(event)}!#{event.source_address.to_s(16)} -> #{ConsoleLogger.gen_source(generator)}::#{ConsoleLogger.gen_name(generator)}")
	end
	def task_initialize(time, task, start, stop) # :nodoc:
	    display(time, task.name, "", "new_task")
	end
    end
end

