require 'roby/log/logger'
require 'roby/distributed'

module Roby::Log
    # A logger object which marshals events in a IO object. The log files can
    # be replayed (for off-line display) by calling FileLogger.replay(io)
    class FileLogger
	@dumped = Hash.new
	class << self
	    attr_reader :dumped
	end

	attr_reader :io
	def initialize(file)
	    @io = File.open(file, 'w')
	end
	def splat?; false end

	def dump_method(m, args)
	    Marshal.dump(m, io)
	    Marshal.dump(args, io)
	rescue 
	    STDERR.puts "failed to dump #{m}#{args}: #{$!.full_message}"
	end

	Roby::Log.each_hook do |klass, m|
	    define_method(m) { |args| dump_method(m, args) }
	end

	def self.replay(io)
	    method_name = nil
	    loop do
		method_name = Marshal.load(io)
		method_args = Marshal.load(io)
		yield(method_name, method_args)
	    end

	rescue EOFError
	rescue
	    if method_name
		STDERR.puts "handling of #{method_name} failed with: #{$!.full_message}"
	    else
		raise
	    end
	end
    end
end

