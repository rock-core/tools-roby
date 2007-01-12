require 'roby/log/hooks'

module Roby::Log
    @loggers = Array.new
    class << self
	# All logger objects in the system
	attr_reader :loggers

	# Iterates on all the logger objects. If +m+ is given, yields only the loggers
	# which respond to this method.
	def each_logger(m = nil)
	    @loggers.each do |log|
		yield(log) if !m || log.respond_to?(m)
	    end
	end

	# Returns true if there is at least one loggr for the +m+ message
	def has_logger?(m); loggers.any? { |log| log.respond_to?(m) } end

	# call-seq:
	#   Log.log(message) { args }
	#
	# Logs +message+ with argument +args+. The block is called only once if
	# there is at least one logger which listens for +message+.
	def log(m, args = nil)
	    Roby::Control.synchronize do
		each_logger(m) do |log|
		    if !args && block_given?
			args ||= yield
		    end
		    log.send(m, *args)
		end
	    end
	end

	def flush
	    each_logger(:flush) do |log|
		log.flush
	    end
	end

	# Requires all displays
	def load_all_displays
	    require 'roby/log/relations'
	    require 'roby/log/execution-state'
	end
    end

end

