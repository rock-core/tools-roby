require 'roby/log/logger'

module Roby::Log
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
	    @columns = Hash.new { |h, k| h[k] = Array.new }
	end

	def display(time, m, *args) # :nodoc:
	    @reftime ||= time

	    args.map!(&ConsoleLogger.method(:filter_names))
	    args.unshift(m).
		unshift(Time.at(time - @reftime).to_hms)
		
	    columns = self.columns[m]
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

	[TransactionHooks, PlanHooks, TaskHooks, EventGeneratorHooks, ControlHooks].each do |klass|
	    klass::HOOKS.each do |m|
		define_method(m) { |time, *args| display(time, m, *args.map { |a| a.to_s }) }
	    end
	end
    end
end

