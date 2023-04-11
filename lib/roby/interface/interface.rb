# frozen_string_literal: true

module Roby
    module Interface
        # The job's planning task is ready to be executed
        JOB_PLANNING_READY   = :planning_ready
        # The job's planning task is running
        JOB_PLANNING         = :planning
        # The job's planning task has failed
        JOB_PLANNING_FAILED  = :planning_failed
        # The job's main task is ready to be executed
        JOB_READY            = :ready
        # The job is started
        JOB_STARTED          = :started
        # The job has finished successfully
        JOB_SUCCESS          = :success
        # The job has failed
        JOB_FAILED           = :failed
        # The job has finished
        JOB_FINISHED         = :finished
        # The job has been finalized (i.e. removed from plan)
        JOB_FINALIZED        = :finalized

        # The job has been dropped, i.e. its mission status has been removed
        JOB_DROPPED          = :dropped

        # Initial notification, when the interface starts monitoring a job
        JOB_MONITORED        = :monitored
        # The job got replaced by a task that is not this job
        JOB_LOST             = :lost
        # The job placeholder task got replaced, and the replacement is managed
        # under the same job
        JOB_REPLACED         = :replaced

        # Whether the given state indicates that the job's planning is finished
        def self.planning_finished_state?(state)
            ![JOB_PLANNING_READY, JOB_PLANNING, JOB_FINALIZED].include?(state)
        end

        # Tests if the given state (one of the JOB_ constants) is terminal, e.g.
        # means that the job is finished
        def self.terminal_state?(state)
            [JOB_PLANNING_FAILED, JOB_FAILED, JOB_SUCCESS, JOB_FINISHED, JOB_FINALIZED].include?(state)
        end

        # Tests if the given state (one of the JOB_ constants) means that the
        # job finished successfully
        def self.success_state?(state)
            [JOB_SUCCESS].include?(state)
        end

        # Tests if the given state (one of the JOB_ constants) means that the
        # job finished with error
        def self.error_state?(state)
            [JOB_PLANNING_FAILED, JOB_FAILED].include?(state)
        end

        # Tests if the given state (one of the JOB_ constants) means that the
        # job is still running
        def self.running_state?(state)
            [JOB_STARTED].include?(state)
        end

        # Tests if the given state (one of the JOB_ constants) means that the
        # job has been finalized (removed from plan)
        def self.finalized_state?(state)
            [JOB_FINALIZED].include?(state)
        end

        # The server-side implementation of the command-based interface
        #
        # This exports all the services and/or APIs that are available through e.g.
        # the Roby shell. It does not do any marshalling/demarshalling
        #
        # Most methods can be accessed outside of the Roby execution thread. Methods
        # that cannot will be noted in their documentation
        #
        # == About job management
        # One of the tasks of this class is to do job management. Jobs are the
        # unit that is used to interact with a running Roby instance at a high
        # level, as e.g. through a shell or a GUI. In Roby, jobs are represented
        # by tasks that provide the {Job} task service and have a
        # non-nil job ID. Up to two tasks can be associated with the job. The
        # first is obviously the job task itself, i.e. the task that provides
        # {Job}. Quite often, the job task will be a planning task
        # (actually, one can see that {Actions::Task} provides
        # {Job}). In this case, the planned task will be also
        # associated with the job as its placeholder: while the job task
        # represents the job's deployment status, the placeholder task will
        # represent the job's execution status.
        class Interface < CommandLibrary
            # @return [#call] the blocks that listen to job notifications. They are
            #   added with {#on_job_notification} and removed with
            #   {#remove_job_listener}
            attr_reader :job_listeners

            # @return [#call] the blocks that listen to end-of-cycle
            #   notifications. They are added with {#on_cycle_end} and
            #   removed with {#remove_cycle_end}
            attr_reader :cycle_end_listeners

            # @api private
            #
            # @return [Set<Integer>] the set of tracked jobs
            # @see tracked_job?
            attr_reader :tracked_jobs
            # @api private
            #
            # The set of pending job notifications for this cycle
            attr_reader :job_notifications

            # Creates an interface from an existing Roby application
            #
            # @param [Roby::Application] app the application
            def initialize(app)
                super(app)

                @tracked_jobs = Set.new
                @job_notifications = []
                @job_listeners = []
                @exception_notifications = []
                @exception_listeners = []
                @job_monitoring_state = {}
                @cycle_end_listeners = []

                app.plan.add_trigger Roby::Interface::Job do |task|
                    if task.job_id && (planned_task = task.planned_task)
                        monitor_job(task, planned_task, new_task: true)
                    end
                end
                execution_engine.on_exception(on_error: :raise) do |kind, exception, tasks|
                    involved_job_ids = tasks
                        .flat_map { |t| job_ids_of_task(t) if t.plan }
                        .compact.to_set
                    @exception_notifications << [kind, exception, tasks, involved_job_ids]
                end
                execution_engine.at_cycle_end do
                    push_pending_notifications
                    notify_cycle_end
                end
            end

            State = Struct.new :service, :monitored, :job_id, :job_name do
                def monitored?
                    monitored
                end
            end

            # Returns the port of the log server
            #
            # @return [Integer,nil] the port, or nil if there is no log server
            def log_server_port
                app.log_server_port
            end
            command :log_server_port, "returns the port of the log server",
                    advanced: true

            # The set of actions available on {#app}
            #
            # @return [Array<Roby::Actions::Models::Action>]
            def actions
                result = []
                app.planners.each do |planner_model|
                    planner_model.each_registered_action do |_, act|
                        result << act
                    end
                end
                result
            end
            command :actions, "lists a summary of the available actions"

            # Starts a job
            #
            # @return [Integer] the job ID
            def start_job(m, arguments = {})
                _task, planning_task = app.prepare_action(m, mission: true,
                                                             job_id: Job.allocate_job_id, **arguments)
                planning_task.job_id
            end

            # Kill a job
            #
            # It removes the job from the list of missions and kills the job's
            # main task
            #
            # @param [Integer] job_id the ID of the job that should be
            #   terminated
            # @return [Boolean] true if the job was found and terminated, and
            #   false otherwise
            # @see drop_job
            def kill_job(job_id)
                if task = find_job_placeholder_by_id(job_id)
                    plan.unmark_mission_task(task)
                    task.stop! if task.running?
                    true
                else
                    false
                end
            end
            command :kill_job, "forcefully kills the given job",
                    job_id: "the job ID. It is the return value of the xxx! command and can also be obtained by calling jobs"

            # Drop a job
            #
            # It removes the job from the list of missions but does not
            # explicitely kill it
            #
            # @param [Integer] job_id the ID of the job that should be
            #   terminated
            # @return [Boolean] true if the job was found and terminated, and
            #   false otherwise
            # @see kill_job
            def drop_job(job_id)
                return unless (task = find_job_by_id(job_id))

                placeholder_task = task.planned_task
                unless placeholder_task
                    plan.unmark_mission_task(task)
                    return true
                end

                placeholder_task.remove_planning_task(task)
                if job_ids_of_task(placeholder_task).empty?
                    plan.unmark_mission_task(placeholder_task)
                    true
                else
                    false
                end
            end
            command :drop_job, "remove this job from the list of jobs, this does not necessarily kill the job's main task",
                    job_id: "the job ID. It is the return value of the xxx! command and can also be obtained by calling jobs"

            # Enumerates the job listeners currently registered through
            # {#on_job_notification}
            #
            # @yieldparam [#call] the job listener object
            def each_job_listener(&block)
                job_listeners.each(&block)
            end

            # Dispatch the given job-related notification to all listeners
            #
            # Listeners are registered with {#on_job_notification}
            def job_notify(kind, job_id, job_name, *args)
                job_notifications << [kind, job_id, job_name, args]
            end

            # @api private
            #
            # Called in at_cycle_end to push job notifications
            def push_pending_notifications
                final_tracked_jobs = tracked_jobs.dup

                # Re-track jobs for which we have a recapture event
                job_notifications.each do |event, job_id, *|
                    if event == JOB_MONITORED
                        tracked_jobs << job_id
                        final_tracked_jobs << job_id
                    elsif [JOB_DROPPED, JOB_LOST, JOB_FINALIZED].include?(event)
                        final_tracked_jobs.delete(job_id)
                    end
                end

                job_notifications = self.job_notifications.find_all do |event, job_id, *|
                    case event
                    when JOB_FINALIZED
                        true
                    when JOB_DROPPED
                        !final_tracked_jobs.include?(job_id)
                    else
                        tracked_jobs.include?(job_id)
                    end
                end
                self.job_notifications.clear

                each_job_listener do |listener|
                    job_notifications.each do |kind, job_id, job_name, args|
                        listener.call(kind, job_id, job_name, *args)
                    end
                end

                exception_notifications = @exception_notifications
                @exception_notifications = []
                exception_notifications.each do |kind, exception, tasks, involved_job_ids|
                    @exception_listeners.each do |block|
                        block.call(kind, exception, tasks, involved_job_ids)
                    end
                end

                @tracked_jobs = final_tracked_jobs
            end

            # (see Application#on_ui_event)
            def on_ui_event(&block)
                app.on_ui_event(&block)
            end

            # (see Application#remove_ui_event_listener)
            def remove_ui_event_listener(listener)
                app.remove_ui_event_listener(listener)
            end

            # (see Application#on_notification)
            def on_notification(&block)
                app.on_notification(&block)
            end

            # (see Application#remove_notification_listener)
            def remove_notification_listener(listener)
                app.remove_notification_listener(listener)
            end

            # Registers a block to be called when a job changes state
            #
            # All callbacks will be called with at minimum
            #
            # @overload on_job_notification
            #   @yieldparam kind one of the JOB_* constants
            #   @yieldparam [Integer] job_id the job ID (unique)
            #   @yieldparam [String] job_name the job name (non-unique)
            #
            #   Generic interface. Some of the notifications, detailed below,
            #   have additional parameters (after the job_name argument)
            #
            # @overload on_job_notification
            #   @yieldparam JOB_MONITORED
            #   @yieldparam [Integer] job_id the job ID (unique)
            #   @yieldparam [String] job_name the job name (non-unique)
            #   @yieldparam [Task] task the job's placeholder task
            #   @yieldparam [Task] job_task the job task
            #
            #   Interface for JOB_MONITORED notifications, called when the job
            #   task is initially detected
            #
            # @overload on_job_notification
            #   @yieldparam JOB_REPLACED or JOB_LOST
            #   @yieldparam [Integer] job_id the job ID (unique)
            #   @yieldparam [String] job_name the job name (non-unique)
            #   @yieldparam [Task] task the new task this job is now tracking
            #
            #   Interface for JOB_REPLACED and JOB_LOST notifications
            #
            # @return [Object] the listener ID that can be given to
            #   {#remove_job_listener}
            def on_job_notification(&block)
                job_listeners << block
                Roby.disposable { job_listeners.delete(block) }
            end

            # Remove a job listener added with {#on_job_notification}
            #
            # @param [Object] listener the listener ID returned by
            #   {#on_job_notification}
            def remove_job_listener(listener)
                listener.dispose if listener.respond_to?(:dispose)
            end

            # Returns all the job IDs of this task
            #
            # @param [Roby::Task] task the job task itself, or its placeholder
            #   task
            # @return [Array<Integer>] the task's job IDs. May be empty if
            #   the task is not a job task, or if its job ID is not set
            def job_ids_of_task(task)
                if task.fullfills?(Job)
                    [task.job_id]
                else
                    task.each_planning_task.map do |planning_task|
                        if planning_task.fullfills?(Job)
                            planning_task.job_id
                        end
                    end.compact
                end
            end

            # Returns the job ID of a task, where the task can either be a
            # placeholder for the job or the job task itself
            #
            # @return [Integer,nil] the task's job ID or nil if (1) the task is
            #   not a job task or (2) its job ID is not set
            def job_id_of_task(task)
                job_ids_of_task(task).first
            end

            # Monitor the given task as a job
            #
            # It must be called within the Roby execution thread
            def monitor_job(planning_task, task, new_task: false)
                # NOTE: this method MUST queue job notifications
                # UNCONDITIONALLY. Job tracking is done on a per-cycle basis (in
                # at_cycle_end) by {#push_pending_notifications}

                job_id   = planning_task.job_id
                job_name = planning_task.job_name

                # This happens when a placeholder/planning pair is replaced by
                # another, but the job ID is inherited. We do this when e.g.
                # running an action that returns another planning pair
                if (state = @job_monitoring_state[job_id])
                    track_planning_state(
                        state.job_id, state.job_name, state.service, planning_task)
                    return
                end

                service = PlanService.new(task)
                @job_monitoring_state[job_id] =
                    State.new(service, false, job_id, job_name)
                service.when_finalized do
                    @job_monitoring_state.delete(job_id)
                end

                service.on_plan_status_change(initial: true) do |status|
                    state = @job_monitoring_state[job_id]
                    if !state.monitored? && (status == :mission)
                        job_notify(JOB_MONITORED, job_id, job_name, service.task,
                                   service.task.planning_task)
                        job_notify(job_state(service.task), job_id, job_name)
                        state.monitored = true
                    elsif state.monitored? && (status != :mission)
                        job_notify(JOB_DROPPED, job_id, job_name)
                        state.monitored = false
                    end
                end

                track_planning_state(job_id, job_name, service, planning_task)

                service.on_replacement do |_current, new|
                    if plan.mission_task?(new) && job_ids_of_task(new).include?(job_id)
                        job_notify(JOB_REPLACED, job_id, job_name, new)
                        job_notify(job_state(new), job_id, job_name)
                    else
                        job_notify(JOB_LOST, job_id, job_name, new)
                    end
                end
                service.on(:start) do |ev|
                    job_notify(JOB_STARTED, job_id, job_name)
                end
                service.on(:success) do |ev|
                    job_notify(JOB_SUCCESS, job_id, job_name)
                end
                service.on(:failed) do |ev|
                    job_notify(JOB_FAILED, job_id, job_name)
                end
                service.when_finalized do
                    job_notify(JOB_FINALIZED, job_id, job_name)
                end
            end

            private def track_planning_state(job_id, job_name, service, planning_task)
                planning_task.start_event.on do |ev|
                    job_task = planning_task.planned_task
                    if job_task == service.task
                        job_notify(JOB_PLANNING, job_id, job_name)
                    end
                end
                planning_task.success_event.on do |ev|
                    job_task = planning_task.planned_task
                    if job_task == service.task &&
                       (job_task.pending? || job_task.starting?)
                        job_notify(JOB_READY, job_id, job_name)
                    end
                end
                planning_task.stop_event.on do |ev|
                    job_task = planning_task.planned_task
                    if job_task == service.task && !ev.task.success?
                        job_notify(JOB_PLANNING_FAILED, job_id, job_name)
                    end
                end

                PlanService.new(planning_task).when_finalized do
                    job_task = planning_task.planned_task
                    if job_task == service.task
                        job_notify(JOB_FINALIZED, job_id, job_name)
                    end
                end
            end

            def job_state(task)
                if !task.plan
                    JOB_FINALIZED
                elsif !plan.mission_task?(task)
                    JOB_DROPPED
                elsif task.success_event.emitted?
                    JOB_SUCCESS
                elsif task.failed_event.emitted?
                    JOB_FAILED
                elsif task.stop_event.emitted?
                    JOB_FINISHED
                elsif task.running?
                    JOB_STARTED
                elsif task.pending?
                    if planner = task.planning_task
                        if planner.success?
                            JOB_READY
                        elsif planner.stop?
                            JOB_PLANNING_FAILED
                        elsif planner.running?
                            JOB_PLANNING
                        else
                            JOB_PLANNING_READY
                        end
                    else
                        JOB_READY
                    end
                end
            end

            # The jobs currently running on {#app}'s plan
            #
            # @return [Hash<Integer,(Symbol,Roby::Task,Roby::Task)>] the mapping
            #   from job ID to the job's state (as returned by {#job_state}), the
            #   placeholder job task and the job task itself
            def jobs
                result = {}
                planning_tasks = plan.find_tasks(Job).to_a
                planning_tasks.each do |job_task|
                    job_id = job_task.job_id
                    next unless job_id

                    placeholder_job_task = job_task.planned_task || job_task
                    result[job_id] = [
                        job_state(placeholder_job_task),
                        placeholder_job_task,
                        job_task
                    ]
                end
                result
            end
            command :jobs, "returns the list of non-finished jobs"

            def find_job_info_by_id(id)
                if planning_task = plan.find_tasks(Job).with_arguments(job_id: id).to_a.first
                    task = planning_task.planned_task || planning_task
                    [job_state(task), task, planning_task]
                end
            end

            # Finds a job task by its ID
            #
            # @param [Integer] id
            # @return [Roby::Task,nil]
            def find_job_by_id(id)
                plan.find_tasks(Job).with_arguments(job_id: id).to_a.first
            end

            # Finds the task that represents the given job ID
            #
            # It can be different than the job task when e.g. the job task is a
            # planning task
            def find_job_placeholder_by_id(id)
                if task = find_job_by_id(id)
                    task.planned_task || task
                end
            end

            # Reload all models from this Roby application
            #
            # Do NOT do this while the robot does critical things
            def reload_models
                app.reload_models
                nil
            end

            # @deprecated use {#reload_actions} instead
            def reload_planners
                reload_actions
            end

            # Reload the actions defined under the actions/ subfolder
            def reload_actions
                app.reload_actions
                actions
            end
            command :reload_actions, "reloads the files in models/actions/"

            # Notification about plan exceptions
            #
            # @yieldparam [Symbol] kind one of {ExecutionEngine::EXCEPTION_NONFATAL},
            #   {ExecutionEngine::EXCEPTION_FATAL} or {ExecutionEngine::EXCEPTION_HANDLED}
            # @yieldparam [Roby::ExecutionException] error the exception
            # @yieldparam [Array<Roby::Task>] tasks the tasks that are involved in this exception
            # @yieldparam [Set<Integer>] job_ids the job ID of the involved jobs
            #
            # @see ExecutionEngine#on_exception
            def on_exception(&block)
                @exception_listeners << block
                Roby.disposable { @exception_listeners.delete(block) }
            end

            # @see ExecutionEngine#remove_exception_listener
            def remove_exception_listener(listener)
                listener.dispose
            end

            # Add a handler called at each end of cycle
            #
            # Interface-related objects that need to be notified must use this
            # method instead of using {ExecutionEngine#at_cycle_end} on
            # {#execution_engine}, because the listener is guaranteed to be ordered
            # properly w.r.t. {#push_pending_notifications}
            #
            # @param [#call] block the listener
            # @yieldparam [ExecutionEngine] the underlying execution execution_engine
            # @return [Object] and ID that can be passed to {#remove_cycle_end}
            def on_cycle_end(&block)
                cycle_end_listeners << block
                Roby.disposable { cycle_end_listeners.delete(block) }
            end

            # @api private
            #
            # Notify the end-of-cycle to the listeners registered with
            # {#on_cycle_end}
            def notify_cycle_end
                cycle_end_listeners.each(&:call)
            end

            # Remove a handler that has been added to {#on_cycle_end}
            def remove_cycle_end(listener)
                listener.dispose if listener.respond_to?(:dispose)
            end

            # Requests for the Roby application to quit
            def quit
                execution_engine.quit
            end
            command :quit, "requests that the Roby application quits"

            # Requests for the Roby application to quit
            def restart
                app.restart
            end
            command :restart, "restart this app's process"

            # This is implemented on ShellClient directly
            command "describe", "gives details about the given action",
                    action: "the action itself"

            # This is implemented on Server directly
            command "enable_notifications", "enables the forwarding of notifications"
            command "disable_notifications", "disables the forwarding of notifications"

            # Enable or disable backtrace filtering
            def enable_backtrace_filtering(enable: true)
                app.filter_backtraces = enable
            end
            command :enable_backtrace_filtering, "enable or disable backtrace filtering",
                    enable: "true to enable, false to disable",
                    advanced: true

            # Returns the app's log directory
            def log_dir
                app.log_dir
            end
            command :log_dir, "the app's log directory",
                    advanced: true
        end
    end
end
