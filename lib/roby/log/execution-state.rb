require 'roby/log/marshallable'
require 'roby/log/drb'
require 'roby/log/hooks'

module Roby::Display
    class ExecutionState < DRbRemoteDisplay
	include Singleton

	class << self
	    def connect(options = {})
		Roby::Log.loggers << instance
		instance.connect("execution_state", options)
	    end
	end

	PING_PERIOD = 1

	[:generator_calling, :generator_signalling, :generator_fired].each do |m| 
	    define_method(m) do |*args| 
		@last_ping = args[0]
		display_thread.send(m, *args)
	    end
	end

	def cycle_end(time, timings)
	    if !@last_ping || (time - @last_ping > PING_PERIOD)
		display_thread.cycle_end(time, timings)
		@last_ping = time
	    end
	end

	def disabled
	    Roby::Log.loggers.delete(self)
	    super
	end
    end
end

