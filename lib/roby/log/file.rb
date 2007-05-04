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
	# The set of events for the current cycle. This is dumped only
	# when the +cycle_end+ event is received
	attr_reader :current_cycle

	def initialize(basename)
	    @current_pos   = 0
	    @current_cycle = Array.new
	    @event_log = File.open("#{basename}-events.log", 'w')
	    event_log.sync = true
	    @index_log = File.open("#{basename}-index.log", 'w')
	    index_log.sync = true
	end
	def splat?; false end

	def dump_method(m, args)
	    if m == :cycle_end
		info = args[1].dup
		info[:pos] = event_log.tell
		Marshal.dump(current_cycle, event_log)
		Marshal.dump(info, index_log)
		current_cycle.clear
	    else
		current_cycle << m << args
	    end

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
	
	# Creates an index file for +event_log+ in +index_log+
	def self.rebuild_index(event_log, index_log)
	    event_log.rewind
	    current_pos = 0

	    loop do
		m    = Marshal.load(event_log)
		args = Marshal.load(event_log)
		if m == :cycle_end
		    info = args[1]
		    info[:pos] = current_pos
		    Marshal.dump(info, index_log)
		    current_pos = event_log.tell
		end
	    end

	rescue EOFError
	ensure
	    event_log.rewind
	    index_log.rewind
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

