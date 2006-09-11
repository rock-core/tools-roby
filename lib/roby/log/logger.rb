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
	    basedir = File.dirname(__FILE__)
	    Dir.glob("#{basedir}/*") do |path|
		next unless File.directory?(path)
		req = File.basename(path).gsub('_', '-')
		next unless File.file?("#{path}/server.rb") && File.file?("#{basedir}/#{req}.rb")
		require "roby/log/#{req}"
	    end

	    ObjectSpace.enum_for(:each_object, Class).
		find_all { |k| k < Roby::Display::DRbRemoteDisplay && k.respond_to?(:connect) }
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
end

