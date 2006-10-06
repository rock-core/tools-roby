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
	    display(time, ConsoleLogger.gen_source(gen), ConsoleLogger.gen_name(gen), "call", "ctxt=#{context}")
	end
	def generator_fired(time, event) # :nodoc:
	    display(time, ConsoleLogger.gen_source(event.generator), 
		    ConsoleLogger.gen_name(event.generator), "fired", 
		    "#{ConsoleLogger.gen_name(event)}!#{event.source_address.to_s(16)} ctxt=#{event.context}")
	end
	def generator_signalling(time, event, generator) # :nodoc:
	    display(time, ConsoleLogger.gen_source(event.generator), 
		    ConsoleLogger.gen_name(event.generator), "signal", 
		    "#{ConsoleLogger.gen_name(event)}!#{event.source_address.to_s(16)} -> #{ConsoleLogger.gen_source(generator)}::#{ConsoleLogger.gen_name(generator)}")
	end
	def task_initialize(time, task, start, stop) # :nodoc:
	    display(time, task.name, "", "new_task")
	end
	def finalized_task(time, plan, task)
	    display(time, task.name, "", "finalized")
	end
    end
end

