# frozen_string_literal: true

module Roby
    @state = Roby::StateSpace.new
    @conf = Roby::ConfModel.new

    class << self
        # The one and only Application object
        def app
            @app ||= Application.new
        end

        # The one and only StateSpace object
        attr_reader :state

        # The one and only ConfModel object
        attr_reader :conf

        # The main plan
        #
        # It is always the same as Roby.app.plan
        #
        # @return [Plan]
        def plan
            app.plan
        end

        # The main execution engine
        #
        # It is always the same as Roby.plan.execution_engine
        #
        # Note that it is nil until the Roby application is configured
        #
        # @return [ExecutionEngine]
        def execution_engine
            app.execution_engine
        end

        # The main scheduler
        #
        # It is always the same as Roby.plan.execution_engine.scheduler
        def scheduler
            app.plan.execution_engine.scheduler
        end

        # Sets the main scheduler
        #
        # It is always the same as Roby.plan.execution_engine.scheduler
        def scheduler=(scheduler)
            app.plan.execution_engine.scheduler = scheduler
        end

        # The control / policy object
        #
        # This is the object that defines the core execution policies (e.g. what
        # to do if the dependency of a non-running task stops). See
        # {DecisionControl}
        def control
            app.plan.execution_engine.control
        end

        # Sets the control / policy object
        #
        # This is the object that defines the core execution policies (e.g. what
        # to do if the dependency of a non-running task stops). See
        # {DecisionControl}
        def control=(object)
            app.plan.execution_engine.control = object
        end

        # @deprecated use {Roby.execution_engine} instead
        def engine
            Roby.warn_deprecated "Roby.engine is deprecated, use Roby.execution_engine instead"
            app.execution_engine
        end
    end

    # Defines a global exception handler on the main plan.
    # See also Plan#on_exception
    def self.on_exception(matcher, &handler)
        Roby.app.plan.on_exception(matcher, &handler)
    end

    # The main state object
    State = Roby.state
    # The main configuration object
    Conf  = Roby.conf
end

# The main state object
State = Roby.state
# The main configuration object
Conf  = Roby.conf
