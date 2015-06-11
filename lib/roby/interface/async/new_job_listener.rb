module Roby
    module Interface
        module Async
            # Listener object for {Interface#on_job}
            class NewJobListener
                attr_reader :interface
                attr_reader :action_name
                attr_reader :block

                # The last ID of the jobs received by this listener.
                #
                # This is used to avoid double-notifications of new jobs. The
                # assumption is that the job IDs are ever-increasing and that
                # they are fed in-order to {#call}.
                attr_reader :last_job_id

                def initialize(interface, action_name, block)
                    @interface = interface
                    @action_name = action_name
                    @block = block
                    @last_job_id = -1
                end

                # Resets the listener so that it can be used on a new connection
                #
                # This currently only resets {#last_job_id}
                def reset
                    @last_job_id = -1
                end

                # Tests whether this listener has already seen the job with the
                # given ID
                #
                # @param [Integer] job_id
                # @see last_job_id
                def seen_job_with_id?(job_id)
                    last_job_id < job_id
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
                    @last_job_id = job.job_id
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
