require 'roby/test/common'

module Roby
    module Test
    # This module is extending Test to be able to run tests using the normal
    # testrb command. It is meant to be used to test libraries (e.g. Roby
    # itself) as, in complex Roby applications, the setup and teardown steps
    # would be very expensive.
    #
    # @see Test
    module Self
        include Test
        if defined? FlexMock
            include FlexMock::ArgumentTypes
            include FlexMock::MockContainer
        end

        def setup
            Roby.app.log['server'] = false
            Roby.app.plugins_enabled = false
            Roby.app.setup
            Roby.app.prepare

            @plan    = Plan.new
            @control = DecisionControl.new
            if !plan.engine
                ExecutionEngine.new(@plan, @control)
            end

            Roby.app.public_logs = false

            super

	    # Save and restore some arrays
	    save_collection engine.propagation_handlers
	    save_collection engine.external_events_handlers
	    save_collection Roby::ExecutionEngine.propagation_handlers
	    save_collection Roby::ExecutionEngine.external_events_handlers
	    save_collection plan.structure_checks
	    save_collection Roby::Plan.structure_checks
	    save_collection engine.at_cycle_end_handlers
	    save_collection Roby::EventGenerator.event_gathering
	    Roby.app.abort_on_exception = false
	    Roby.app.abort_on_application_exception = true

	    save_collection engine.event_ordering
	    save_collection engine.delayed_events
	    save_collection plan.exception_handlers
        end

        def teardown
            begin
                super
            rescue Exception => e
                teardown_failure = e
            end
            Roby.app.cleanup

        ensure
            if teardown_failure
                raise teardown_failure
            end
        end
    end
    end
    SelfTest = Test::Self
end

