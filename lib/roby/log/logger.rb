require 'roby/log/hooks'

module Roby::Log
    @loggers = Array.new
    class << self
	attr_reader :loggers

	# Iterates on all the logger objects. If +m+ is given, yields only the loggers
	# which respond to this method.
	def each_logger(m = nil)
	    @loggers.each do |log|
		yield(log) if !m || log.respond_to?(m)
	    end
	end

	# Requires all displays. Returns the display classes
	def load_all_displays
	    require 'roby/log/relation-display'
	    require 'roby/log/execution-state'
	    [ConsoleLogger, Roby::Display::EventStructure, Roby::Display::TaskStructure, Roby::Display::ExecutionState]
	end
    end

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
	@dumped[:added_relation] = Marshal.dump(:added_relation)
	def added_relation(time, type, from, to, info)
	    io << FileLogger.dumped[:added_relation] << 
		Marshal.dump([time, type.name, from, to, info.to_s])
	end
	@dumped[:removed_relation] = Marshal.dump(:removed_relation)
	def removed_relation(time, type, from, to)
	    io << FileLogger.dumped[:removed_relation] << 
		Marshal.dump([time, type.name, from, to])
	end

	def self.replay(io)
	    loop do
		method_name = Marshal.load(io)
		method_args = Marshal.load(io)
		if method_name == :added_relation || method_name == :removed_relation
		    method_args[1] = Module.constant(method_args[1])
		end

		Log.each_logger(method_name) do |log|
		    log.send(method_name, *method_args)
		end
	    end
	rescue EOFError
	end
    end

    class ConsoleLogger
	def self.filter_names(name)
	    name.gsub(/Roby::(?:Genom::)?/, '')
	end
	def self.gen_source(gen)
	    if gen.respond_to?(:task) then gen.task.name
	    else 'toplevel'
	    end
	end
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

	def display(time, *args)
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

	def generator_calling(time, gen, context)
	    display(time, ConsoleLogger.gen_source(gen), ConsoleLogger.gen_name(gen), "call", "ctxt=#{context.inspect}")
	end
	def generator_fired(time, event)
	    display(time, ConsoleLogger.gen_source(event.generator), 
		    ConsoleLogger.gen_name(event.generator), "fired", 
		    "#{ConsoleLogger.gen_name(event)}!#{event.source_address.to_s(16)} ctxt=#{event.context.inspect}")
	end
	def generator_signalling(time, event, generator)
	    display(time, ConsoleLogger.gen_source(event.generator), 
		    ConsoleLogger.gen_name(event.generator), "signal", 
		    "#{ConsoleLogger.gen_name(event)}!#{event.source_address.to_s(16)} -> #{ConsoleLogger.gen_source(generator)}::#{ConsoleLogger.gen_name(generator)}")
	end
	def task_initialize(time, task, start, stop)
	    display(time, task.name, "", "new_task")
	end
    end
end

