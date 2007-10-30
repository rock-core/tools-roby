
module Roby
    # Fault injection plugin for Roby
    #
    # At each cycles, Application#fault_models[task_model] defines the
    # probability to be emitted for some events of +task_model+: it returns a
    # event_model => object hash, where +object+ is either a number or an
    # object responding to #call which returns a number.  This number is the
    # probability for +event_model+ to be emitted at this cycle.
    #
    # Fault injection applies only on tasks which are running and interruptible.
    #
    # For instance, to say that all tasks have a .5 probability to terminate
    # at each cycle, do
    #
    #	Roby.app.fault_models[Roby::Task][:stop] = 0.5
    #
    # More interesting fault models can be implemented on top of this by using
    # the #call form.
    module FaultInjection
	module Application
	    attribute(:fault_models) do
		Hash.new { |h, k| h[k] = Hash.new }
	    end
	end
    end

    Application.register_plugin('fault_injection', Roby::FaultInjection::Application) do
	require 'fault_injection'
	Roby::Control.each_cycle do
	    FaultInjection.apply(Roby.app.fault_models)
	end
    end
end
