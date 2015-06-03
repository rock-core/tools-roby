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
                include Hooks
                include Hooks::InstanceHooks

                # Hooks called when there is an upcoming notification
                define_hooks :on_progress, call_procs_in_original_context: true

                attr_reader :interface
                attr_reader :job_id
                attr_reader :task
                attr_reader :state

                def initialize(interface, job_id, state: nil, task: nil)
                    @interface = interface
                    @job_id = job_id
                    @state = state || :reachable
                    @task = task
                end

                def inspect
                    "#<JobMonitor #{interface} job_id=#{job_id} state=#{state} task=#{task}>"
                end

                def update_state(state)
                    @state = state
                    run_hook :on_progress, state
                    if state == :finalized
                        stop
                    end
                end

                def terminated?
                    Roby::Interface.terminal_state?(state)
                end

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

