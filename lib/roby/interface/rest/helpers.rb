# frozen_string_literal: true

module Roby
    module Interface
        module REST
            module Helpers
                # The underlying Roby interface
                #
                # @return [Roby::Interface]
                def interface
                    env.fetch("roby.interface")
                end

                # The underlying Roby app
                #
                # @return [Roby::Application]
                def roby_app
                    @roby_app ||= interface.app
                end

                # The underlying Roby plan
                #
                # @return [Roby::ExecutablePlan]
                def roby_plan
                    roby_app.plan
                end

                # A permanent storage hash
                def roby_storage
                    env.fetch("roby.storage")
                end

                # The underlying Roby execution engine
                #
                # @return [Roby::ExecutablePlan]
                def execution_engine
                    @execution_engine ||= interface.execution_engine
                end

                # Execute a block in a context synchronzied with the engine
                def roby_execute(&block)
                    execution_engine.execute(&block)
                end

                # @deprecated use {#roby_execute} instead
                def execute(&block)
                    return super unless block_given?

                    Roby.warn_deprecated "Helpers#execute is deprecated, "\
                                         "use #roby_execute instead"
                    roby_execute(&block)
                end
            end
        end
    end
end
