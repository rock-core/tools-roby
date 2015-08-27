module Roby
    module Interface
        module Async
            # An action definition
            #
            # While {JobMonitor} represents a running / instanciated job, this
            # represents just an action with a set of argument. It binds
            # automatically to a matching running job if there is one.
            class ActionMonitor
                # The underlying Async::Interface
                attr_reader :interface
                # The action name
                attr_reader :action_name
                # The arguments that are part of the job definition itself
                attr_reader :static_arguments
                # The arguments that have been set to override the static
                # arguments, or set arguments not yet set in {#static_arguments}
                attr_reader :arguments
                # The underlying {JobMonitor} object if we're tracking a job
                attr_reader :async

                include Hooks
                include Hooks::InstanceHooks

                # @!method on_progress
                #
                #   Hooks called when self got updated
                #
                #   @return [void]
                define_hooks :on_progress

                # Whether there is a job matching this action monitor running
                def exists?
                    !!async
                end

                # If at least one job ran and is terminated
                def terminated?
                    async && async.terminated?
                end

                # The job ID of the last job that ran
                def job_id
                    async && async.job_id
                end

                # Start or restart a job based on this action
                def restart
                    # Note: we cannot use JobMonitor#restart as the arguments
                    # might have changed in the meantime
                    batch = interface.client.create_batch
                    if async && !async.terminated?
                        batch.kill_job(async.job_id)
                    end
                    batch.send("#{action_name}!", static_arguments.merge(arguments))
                    job_id = batch.process.last
                    self.async = interface.monitor_job(job_id)
                end

                def initialize(interface, action_name, static_arguments = Hash.new)
                    @interface, @action_name, @static_arguments =
                        interface, action_name, static_arguments
                    @arguments = Hash.new

                    interface.on_reachable do
                        run_hook :on_progress
                    end
                    interface.on_unreachable do
                        unreachable!
                    end
                    interface.on_job(action_name: action_name) do |job|
                        if !self.async || self.job_id != job.job_id || terminated?
                            matching = static_arguments.all? do |arg_name, arg_val|
                                job.task.action_arguments[arg_name,to_sym] == arg_val
                            end
                            if matching
                                self.async = job
                                job.start
                            end
                        end
                    end
                end

                def running?
                    async && async.running?
                end

                def state
                    if interface.reachable?
                        if !async
                            :reachable
                        else
                            async.state
                        end
                    else
                        :unreachable
                    end
                end

                def unreachable!
                    @async = nil
                    run_hook :on_progress
                end

                def async=(async)
                    @async = async
                    async.on_progress do
                        if self.async == async
                            run_hook :on_progress
                        end
                    end
                    run_hook :on_progress
                end

                def kill
                    async && async.kill
                end
            end
        end
    end
end

