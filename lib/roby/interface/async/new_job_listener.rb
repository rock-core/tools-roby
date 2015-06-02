module Roby
    module Interface
        module Async
            # Listener object for {Interface#on_job}
            class NewJobListener
                attr_reader :interface
                attr_reader :action_name
                attr_reader :block

                def initialize(interface, action_name, block)
                    @interface = interface
                    @action_name = action_name
                    @block = block
                end

                # Tests whether the provided job matches what this listener
                # wants
                def matches?(job)
                    !action_name || (job.task && job.task.action_model.name == action_name)
                end

                # Call the listener for the given job
                #
                # @param [JobMonitor] job
                def call(job)
                    block.call(job)
                end

                def start
                    interface.add_new_job_listener(self)
                end

                def stop
                    interface.remove_new_job_listener(self)
                end
            end
        end
    end
end
