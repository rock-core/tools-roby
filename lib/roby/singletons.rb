module Roby
    @app = Application.new
    @state = Roby::StateSpace.new
    @conf = Roby::ConfModel.new

    class << self
        # The one and only Application object
        attr_reader :app

        # The one and only StateSpace object
        attr_reader :state

        # The one and only ConfModel object
        attr_reader :conf

        # The scheduler object to be used during execution. See
        # ExecutionEngine#scheduler.
        #
        # This is only used during the configuration of the application, and
        # not afterwards. It is also possible to set per-engine through
        # ExecutionEngine#scheduler=
        attr_accessor :scheduler

        # The decision control object to be used during execution. See
        # ExecutionEngine#control.
        #
        # This is only used during the configuration of the application, and
        # not afterwards. It is also possible to set per-engine through
        # ExecutionEngine#control=
        attr_accessor :control

        # The main plan
        #
        # It is always the same as Roby.app.plan
        #
        # @return [Plan]
        def plan; app.plan end

        # The main execution engine
        #
        # It is always the same as Roby.plan.engine
        #
        # Note that it is nil until the Roby application is configured
        #
        # @return [ExecutionEngine]
        def execution_engine
            app.execution_engine
        end

        # @deprecated use {Roby.execution_engine} instead
        def engine
            Roby.warn_deprecated "Roby.engine is deprecated, use Roby.execution_engine instead"
            app.execution_engine
        end
    end
    
    # Defines a global exception handler on the main plan.
    # See also Plan#on_exception
    def self.on_exception(matcher, &handler); Roby.app.plan.on_exception(matcher, &handler) end

    # The main state object
    State = Roby.state
    # The main configuration object
    Conf  = Roby.conf
end

# The main state object
State = Roby.state
# The main configuration object
Conf  = Roby.conf
