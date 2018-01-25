module Roby
    module Interface
        module REST
            module Helpers
                def interface
                    env['roby.interface']
                end

                def roby_app
                    @roby_app ||= interface.app
                end

                def roby_storage
                    env['roby.storage']
                end

                def execution_engine
                    @execution_engine ||= interface.execution_engine
                end
            end
        end
    end
end

