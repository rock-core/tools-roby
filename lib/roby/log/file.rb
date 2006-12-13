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

	Roby::Log.each_hook do |klass, m|
	    define_method(m) do |*args| 
		begin
		    m_m, m_args = Marshal.dump(m), Marshal.dump(args)
		    io << m_m << m_args
		rescue 
		    STDERR.puts "failed to dump #{m}#{args}"
		end
	    end
	end

	def self.replay(io)
	    loop do
		method_name = Marshal.load(io)
		method_args = Marshal.load(io)
		Roby::Log.log(method_name, method_args)
	    end
	rescue EOFError
	ensure
	    Roby::Log.flush
	end
    end
end

