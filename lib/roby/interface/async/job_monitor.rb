module Roby
    module Interface
        module Async
            # Asynchronous monitoring of a job
            #
            # This is usually not created directly, but either by calling
            # {Interface#on_job} or {Interface#find_job}. The jobs created by
            # these two methods are already listening for the job's progress.
            # Call {#stop} to remove the monitor.
            class JobMonitor
                include Roby::Hooks
                include Roby::Hooks::InstanceHooks

                # @!method on_progress
                #   Hook called when there is an upcoming notification
                #
                #   @yieldparam [Symbol] state the new job state
                #   @return [void]
                define_hooks :on_progress

                # @return [Interface] the async interface we are bound to
                attr_reader :interface

                # @return [Integer] the job ID
                attr_reader :job_id

                # @return [Roby::Task] the job's main task
                attr_reader :task

                # @return [Symbol] the job's current state
                attr_reader :state

                def initialize(interface, job_id, state: nil, task: nil)
                    @interface = interface
                    @job_id = job_id
                    @state = state || :reachable
                    @task = task
                end

                # Kill this job and start an equivalent one
                #
                # @return [JobMonitor] the monitor object for the new job. It is
                #   not listening to the new job yet, call {#start} for that
                def restart
                    batch = interface.client.create_batch
                    if !terminated?
                        batch.kill_job(job_id)
                    end
                    batch.send("#{action_name}!", action_arguments)
                    job_id = batch.process.last
                    interface.monitor_job(job_id)
                end

                # The job's action model
                #
                # @return [Roby::Actions::Model::Action,nil]
                def action_model
                    task && task.action_model
                end

                # Returns the job's action name
                #
                # @return [String,nil]
                def action_name
                    task && task.action_model.name
                end

                # Returns the arguments that were passed to the action
                def action_arguments
                    task && task.action_arguments
                end

                # @api private
                def inspect
                    "#<JobMonitor #{interface} job_id=#{job_id} state=#{state} task=#{task}>"
                end

                # @api private
                #
                # @api private
                #
                # Called by {Interface} to update the job's state
                def update_state(state)
                    @state = state
                    run_hook :on_progress, state
                    if state == :finalized
                        stop
                    end
                end

                # Tests whether this job is terminated
                def terminated?
                    Roby::Interface.terminal_state?(state)
                end

                # Tests whether this job is running
                def running?
                    state == :started
                end

                # Start monitoring this job's state
                def start
                    update_state(state)
                    interface.on_unreachable do
                        update_state(:unreachable)
                    end
                    interface.add_job_monitor(self)
                end

                # Stop monitoring this job's state
                def stop
                    interface.remove_job_monitor(self)
                end

                # Send a command to kill this job
                def kill
                    interface.client.kill_job(job_id)
                end
            end
        end
    end
end

