
module Roby
    # Fault injection plugin for Roby
    #
    # Roby::FaultInjection::Application#fault_models defines a set of
    # probabilistic models of emission for task events. It maps task model
    # events to emission models, and during execution will randomly emit
    # events.
    #
    # Fault injection applies only on tasks which are running and interruptible.
    module FaultInjection
	# This module gets included in Roby::Application when the plugin is activated
	module Application
	    # The set of fault models defined for this application. More specifically,
	    # the emission model for an event +ev+ of a task model +model+ is given by
	    #
	    #   emission_model = Roby.app.fault_models[model][ev]
	    #
	    # where +ev+ is a symbol.
	    attribute(:fault_models) do
		Hash.new { |h, k| h[k] = Hash.new }
	    end

	    # call-seq:
	    #   Roby.app.fault_model task_model, emission_model, ev1, ev2, ...
	    #
	    # Defines +emission_model+ as the emission model for the listed
	    # events of task +task_model+. +ev1+, +ev2+ are symbols.
	    #
	    # Emission models are objects which must respond to #fault?(task).
	    # If this predicate returns true for the running task +task+, then
	    # the emission of the tested event will be simulated. The emission
	    # models are tested every one second.
	    #
	    # See Roby::FaultInjection::Rate for an example.
	    def add_fault_model(task_model, *args)
		fault_model = args.pop
		args.each do |ev|
		    fault_models[task_model][ev.to_sym] = fault_model
		end
	    end

            # Called by the Roby application when it starts
            def self.start(app)
                @handler = app.engine.add_propagation_handler(:type => :external_events) do |plan|
                    FaultInjection.apply(app.fault_models, plan)
                end
            end

            # Called by the Roby application when it starts
            def self.cleanup(app)
                if @handler
                    app.engine.remove_propagation_handler(@handler)
                end
            end
	end
    end

    Application.register_plugin('fault_injection', Roby::FaultInjection::Application) do
	require 'fault_injection'
    end
end

