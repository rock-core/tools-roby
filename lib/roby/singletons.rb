module Roby
    @app = Application.new

    class << self
        # The one and only Application object
        attr_reader :app

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
        # @returns [Plan]
        def plan; app.plan end

        # The main execution engine
        #
        # It is always the same as Roby.plan.engine
        #
        # Note that it is nil until the Roby application is configured
        #
        # @returns [ExecutionEngine]
        def engine; app.plan.engine end
    end
    
    # Defines a global exception handler on the main plan.
    # See also Plan#on_exception
    def self.on_exception(*matchers, &handler); Roby.app.plan.on_exception(*matchers, &handler) end

    # The main state object
    State = Roby::StateSpace.new
    # The main configuration object
    Conf  = Roby::ConfModel.new
end

# The main state object
State = Roby::State
# The main configuration object
Conf  = Roby::Conf
