require 'utilrb/time/to_hms'
require 'roby/log/hooks'

module Roby::Log
    # A logger object which dumps events in a human-readable form to an IO object. 
    class ConsoleLogger
	def splat?; false end
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

	def arg_to_s(arg)
	    case arg
	    when Time then Time.at(arg - @reftime).to_hms
	    when Array then arg.map { |v| arg_to_s(v) }.to_s
	    when Hash then arg.map { |k, v| [arg_to_s(k), arg_to_s(v)].join(" => ") }.to_s
	    else arg.to_s
	    end
	end


        def logs_message?(m); true end
        def close; end
	def dump_method(m, time, *args) # :nodoc:
	    @reftime ||= time

	    args.map! { |a| arg_to_s(a) }
	    args.map!(&ConsoleLogger.method(:filter_names))
	    args.unshift(m).
		unshift(Time.at(time - @reftime).to_hms)
		
	    columns = self.columns[m]
	    args.each_with_index do |str, i|
		str = str.to_s
		if !columns[i] || (str.length > columns[i])
		    columns[i] = str.length
		end
	    end

	    args.each_with_index do |arg, i|
		w = columns[i]
		io << ("%-#{w}s  " % arg)
	    end
	    io << "\n"
	rescue
	    STDERR.puts "#{time} #{m} #{args}"
	    raise
	end
	private :display

	Roby::Log.each_hook do |klass, m|
	    define_method(m) { |time, args| dump_method(m, time, args) }
	end
    end
end

