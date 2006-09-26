require 'roby/log/logger'

module Roby::Log
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

	[:finalized_task].each do |m|
	    @dumped[m] = Marshal.dump(m)
	    define_method(m) do |time, plan, task|
		io << FileLogger.dumped[m] <<
		    Marshal.dump([time, plan, task])
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
end

