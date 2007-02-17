require 'roby/log/logger'
require 'roby/distributed'
require 'stringio'

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
	def splat?; false end

	Roby::Log.each_hook do |klass, m|
	    define_method(m) do |args| 
		begin
		    m_m    = Marshal.dump(m)
		    m_args = Roby::Distributed.dump(args)
		    io << m_m << m_args
		rescue 
		    STDERR.puts "failed to dump #{m}#{args}: #{$!.full_message}"
		end
	    end
	end

	def self.replay(io)
	    method_name = nil
	    loop do
		method_name = Marshal.load(io)
		method_args = Marshal.load(io)
		if io.tell == 77302
		    STDERR.puts method_name
		    time, from, type, to, info = *method_args
		    STDERR.puts info.to_s
		    STDERR.puts info[:model].first.inspect

		    raise Interrupt
		end

		Roby::Log.log(method_name, method_args)
	    end
	rescue EOFError
	rescue
	    STDERR.puts "at #{io.tell}, ignoring call to #{method_name}: #{$!.full_message}"
	    raise
	ensure
	    Roby::Log.flush
	end
    end
end

