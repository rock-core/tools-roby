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

	[:generator_calling, :generator_signalling, :generator_fired].each do |m| 
	    define_method(m) { |*args| @service.send(m, *args) }
	end

	def disabled
	    Roby::Log.loggers.delete(service)
	    super
	end
    end
end

