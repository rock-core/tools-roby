require 'roby/log/logger'
require 'roby/distributed'

module Roby::Log
    # A logger object which marshals all available events in two files. The
    # event log is the full log, the index log contains only the timings given
    # to Control#cycle_end, along with the corresponding position in the event
    # log file.
    #
    # You can use FileLogger.replay(io) to send the events back into the
    # logging system (using Log.log), for instance to feed an offline display
    class FileLogger
	@dumped = Hash.new
	class << self
	    attr_reader :dumped
	end

	# The IO object for the event log
	attr_reader :event_log
	# The IO object for the index log
	attr_reader :index_log

	def initialize(basename)
	    @next_pos  = 0
	    @event_log = File.open("#{basename}-events.log", 'w')
	    @index_log = File.open("#{basename}-index.log", 'w')
	end
	def splat?; false end

	def dump_method(m, args)
	    Marshal.dump(m, event_log)
	    Marshal.dump(args, event_log)

	    if m == :cycle_end
		args[1][:pos] = @next_pos
		Marshal.dump(m, index_log)
		Marshal.dump(args, index_log)
	    end
	    @next_pos = event_log.tell

	rescue 
	    puts "failed to dump #{m}#{args}: #{$!.full_message}"
	    args.each do |obj|
		unless (Marshal.dump(obj) rescue nil)
		    puts "there is a problem with"
		    pp obj
		end
	    end
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
		Roby::Log.warn "handling of #{method_name} failed with: #{$!.full_message}"
	    else
		raise
	    end
	end
    end
end

