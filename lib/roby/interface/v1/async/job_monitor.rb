# frozen_string_literal: true

module Roby
    module Interface
        module V1
            module Async
                # Asynchronous monitoring of a job
                #
                # This is usually not created directly, but either by calling
                # {Interface#on_job} or {Interface#find_all_jobs}. The jobs created by
                # these two methods not listening for the job's progress, you must
                # call {#start} on them to start tracking the job progress.
                #
                # Then call {#stop} to remove the monitor.
                class JobMonitor
                    include Roby::Hooks
                    include Roby::Hooks::InstanceHooks

                    JOB_REACHABLE = :reachable

                    # @!group Hooks

                    # @!method on_progress
                    #   Hook called when there is an upcoming notification
                    #
                    #   @yieldparam [Symbol] state the new job state
                    #   @return [void]
                    define_hooks :on_progress

                    # @!method on_planning_failed
                    #   Hook called when we receive a planning failed exception for
                    #   this job
                    #
                    #   @yieldparam (see ExecutionEngine#on_exception)
                    #   @return [void]
                    define_hooks :on_planning_failed

                    # @!method on_exception
                    #   Hook called when we receive an exception involving this job
                    #   Note that a planning failed exception is both received by
                    #   this handler and by {#on_planning_failed}
                    #
                    #   @yieldparam (see ExecutionEngine#on_exception)
                    #   @return [void]
                    define_hooks :on_exception

                    # @!endgroup

                    # @return [Interface] the async interface we are bound to
                    attr_reader :interface

                    # @return [Integer] the job ID
                    attr_reader :job_id

                    # @return [Roby::Task] the job's main task
                    attr_reader :task

                    # @return [Roby::Task] the job's placeholder task
                    attr_reader :placeholder_task

                    # @return [Symbol] the job's current state
                    attr_reader :state

                    def initialize(interface, job_id, state: JOB_REACHABLE, task: nil, placeholder_task: task)
                        @interface = interface
                        @job_id = job_id
                        @success = false
                        @failed = false
                        @has_ran = false
                        @planning_finished = false
                        update_state(state)
                        @task = task
                        @placeholder_task = placeholder_task
                    end

                    # Kill this job and start an equivalent one
                    #
                    # @return [JobMonitor] the monitor object for the new job. It is
                    #   not listening to the new job yet, call {#start} for that
                    def restart
                        batch = interface.client.create_batch
                        unless terminated?
                            batch.kill_job(job_id)
                        end
                        batch.start_job(action_name, action_arguments)
                        job_id = batch.__process.started_jobs_id.first
                        interface.monitor_job(job_id)
                    end

                    def job_name
                        args = task&.arguments
                        (args[:job_name] if args) || action_name
                    end

                    def action_task?
                        task&.respond_to?(:action_model)
                    end

                    # The job's action model
                    #
                    # @return [Roby::Actions::Model::Action,nil]
                    def action_model
                        task&.action_model if action_task?
                    end

                    # Returns the job's action name
                    #
                    # @return [String,nil]
                    def action_name
                        task&.action_model&.name if action_task?
                    end

                    # Returns the arguments that were passed to the action
                    def action_arguments
                        task&.action_arguments if action_task?
                    end

                    # @api private
                    #
                    # Called when the placeholder task got replaced
                    #
                    # @param [Roby::Task] new_task the new task
                    def replaced(new_task)
                        @placeholder_task = new_task
                    end

                    # @api private
                    def inspect
                        "#<JobMonitor #{interface} job_id=#{job_id} state=#{state} task=#{task}>"
                    end

                    # @api private
                    #
                    # Triggers {#on_exception} and {#on_planning_failed} hooks
                    def notify_exception(kind, exception)
                        if exception.exception.kind_of?(PlanningFailedError)
                            job_id = exception.exception.planning_task.arguments[:job_id]
                            if job_id && (job_id == self.job_id)
                                run_hook :on_planning_failed, kind, exception
                            end
                        end
                        run_hook :on_exception, kind, exception
                    end

                    # @api private
                    #
                    # Called by {Interface} to update the job's state
                    def update_state(state)
                        @state = state
                        if state != JOB_REACHABLE
                            @planning_finished ||= Roby::Interface.planning_finished_state?(state)
                            @success ||= Roby::Interface.success_state?(state)
                            @failed  ||= Roby::Interface.error_state?(state)
                            @has_ran ||= (Roby::Interface.planning_finished_state?(state) &&
                                          state != JOB_READY && state != JOB_PLANNING_FAILED)
                        end
                        run_hook :on_progress, state
                    end

                    # Tests whether planning finished
                    def planning_finished?
                        @planning_finished
                    end

                    # Tests whether this job is running
                    def running?
                        Roby::Interface.running_state?(state)
                    end

                    # Tests whether this job ran successfully
                    def success?
                        @success
                    end

                    # Tests whether this job ran and failed
                    def failed?
                        @failed
                    end

                    # Tests whether this job ran and finished
                    def finished?
                        @has_ran && terminated?
                    end

                    # Tests whether this job is terminated
                    def terminated?
                        Roby::Interface.terminal_state?(state)
                    end

                    # Tests whether this job has been finalized
                    def finalized?
                        Roby::Interface.finalized_state?(state)
                    end

                    # Whether this job monitor is still active
                    def active?
                        interface.active_job_monitor?(self)
                    end

                    # Start monitoring this job's state
                    def start
                        update_state(state)
                        interface.add_job_monitor(self)
                    end

                    # Stop monitoring this job's state
                    def stop
                        interface.remove_job_monitor(self)
                    end

                    # Send a command to drop this job
                    def drop
                        interface.client.drop_job(job_id)
                    end

                    # Send a command to kill this job
                    def kill
                        interface.client.kill_job(job_id)
                    end

                    def pretty_print(pp)
                        pp.text "##{job_id} #{action_name}"
                        unless action_arguments.empty?
                            pp.nest(2) do
                                action_arguments.each do |k, v|
                                    pp.breakable
                                    pp.text "#{k}: "
                                    pp.nest(2) { v.pretty_print(pp) }
                                end
                            end
                        end
                        pp.breakable
                        pp.breakable
                        placeholder_task.pretty_print(pp)
                    end
                end
            end
        end
    end
end
