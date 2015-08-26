module Roby
    # Implementation of a job-oriented interface for Roby controllers
    #
    # This is the implementation of e.g. the Roby shell
    module Interface
        JOB_PLANNING_READY   = :planning_ready
        JOB_PLANNING         = :planning
        JOB_PLANNING_FAILED  = :planning_failed
        JOB_READY            = :ready
        JOB_STARTED          = :started
        JOB_SUCCESS          = :success
        JOB_FAILED           = :failed
        JOB_FINISHED         = :finished
        JOB_FINALIZED        = :finalized

        # In addition to the states above, the following constants are used
        # by job notification
        JOB_MONITORED        = :monitored
        JOB_REPLACED         = :replaced

        def self.terminal_state?(state)
            [JOB_PLANNING_FAILED, JOB_FAILED, JOB_FINISHED, JOB_FINALIZED].include?(state)
        end

        def self.success_state?(state)
            [JOB_SUCCESS].include?(state)
        end

        def self.error_state?(state)
            [JOB_PLANNING_FAILED, JOB_FAILED].include?(state)
        end

        def self.running_state?(state)
            [JOB_STARTED].include?(state)
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

            # Creates an interface from an existing Roby application
            #
            # @param [Roby::Application] app the application
            def initialize(app)
                super(app)
                app.plan.add_trigger Roby::Interface::Job do |task|
                    if task.job_id && (planned_task = task.planned_task)
                        monitor_job(task, planned_task)
                    end
                end

                @job_listeners = Array.new
            end

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
            command :actions, 'lists a summary of the available actions'

            # Starts a job
            #
            # @return [Integer] the job ID
            def start_job(m, arguments = Hash.new)
                engine.execute do
                    task, planning_task = app.prepare_action(m, arguments.merge(:job_id => Job.allocate_job_id))
                    app.plan.add_mission(task)
                    planning_task.job_id
                end
            end

            # Kill a job
            #
            # @param [Integer] job_id the ID of the job that should be
            #   terminated
            # @return [Boolean] true if the job was found and terminated, and
            #   false otherwise
            def kill_job(job_id)
                if task = find_job_placeholder_by_id(job_id)
                    plan.unmark_mission(task)
                    task.stop! if task.running?
                    true
                else false
                end
            end
            command :kill_job, 'kills the given job',
                :job_id => 'the job ID. It is the return value of the xxx! command and can also be obtained by calling jobs'

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
                each_job_listener do |listener|
                    listener.call(kind, job_id, job_name, *args)
                end
            end

            # (see Application#on_notification)
            def on_notification(&block)
                app.on_notification(&block)
            end

            # @param (see Application#remove_notification_listener)
            def remove_notification_listener(&listener)
                app.remove_notification_listener(&listener)
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
            #   @yieldparam [Task] job_task the job task
            #
            #   Interface for JOB_MONITORED notifications
            #
            # @overload on_job_notification
            #   @yieldparam JOB_REPLACED
            #   @yieldparam [Integer] job_id the job ID (unique)
            #   @yieldparam [String] job_name the job name (non-unique)
            #   @yieldparam [Task] task the new task this job is now tracking
            #
            #   Interface for JOB_REPLACED notifications
            #
            # @return [Object] the listener ID that can be given to
            #   {#remove_job_listener}
            def on_job_notification(&block)
                job_listeners << block
                block
            end

            # Remove a job listener added with {#on_job_notification}
            #
            # @param [Object] listener the listener ID returned by
            #   {#on_job_notification}
            def remove_job_listener(listener)
                job_listeners.delete(listener)
            end

            # Returns the job ID of a task, where the task can either be a
            # placeholder for the job or the job task itself
            #
            # @return [Integer,nil] the task's job ID or nil if (1) the task is
            #   not a job task or (2) its job ID is not set
            def job_id_of_task(task)
                if task.fullfills?(Job)
                    task.job_id
                elsif task.planning_task && task.planning_task.fullfills?(Job)
                    task.planning_task.job_id
                end
            end

            # Monitor the given task as a job
            #
            # It must be called within the Roby execution thread
            def monitor_job(planning_task, task)
                job_id   = planning_task.job_id
                job_name = planning_task.job_name
                monitor_active = true
                job_notify(JOB_MONITORED, job_id, job_name, task)
                job_notify(job_state(task), job_id, job_name)

                if planner = task.planning_task
                    planner.on :start do |ev|
                        if monitor_active
                            job_notify(JOB_PLANNING, job_id, job_name)
                        end
                    end
                    planner.on :success do |ev|
                        if monitor_active
                            job_notify(JOB_READY, job_id, job_name)
                        end
                    end
                    planner.on :stop do |ev|
                        if monitor_active && !ev.task.success?
                            job_notify(JOB_PLANNING_FAILED, job_id, job_name)
                        end
                    end
                end

                service = PlanService.new(task)
                service.on_replacement do |current, new|
                    monitor_active = (job_id_of_task(new) == job_id)
                    if monitor_active
                        job_notify(JOB_REPLACED, job_id, job_name, new)
                    end
                end
                service.on(:start) do |ev|
                    if monitor_active
                        job_notify(JOB_STARTED, job_id, job_name)
                    end
                end
                service.on(:success) do |ev|
                    if monitor_active
                        job_notify(JOB_SUCCESS, job_id, job_name)
                    end
                end
                service.on(:failed) do |ev|
                    if monitor_active
                        job_notify(JOB_FAILED, job_id, job_name)
                    end
                end
                service.when_finalized do 
                    if monitor_active
                        job_notify(JOB_FINALIZED, job_id, job_name)
                    end
                end
            end

            def job_state(task)
                if !task
                    return JOB_FINALIZED
                elsif task.success_event.happened?
                    return JOB_SUCCESS
                elsif task.failed_event.happened?
                    return JOB_FAILED
                elsif task.stop_event.happened?
                    return JOB_FINISHED
                elsif task.running?
                    return JOB_STARTED
                elsif task.pending?
                    if planner = task.planning_task
                        if planner.success?
                            return JOB_READY
                        elsif planner.stop?
                            return JOB_PLANNING_FAILED
                        elsif planner.running?
                            return JOB_PLANNING
                        else
                            return JOB_PLANNING_READY
                        end
                    else return JOB_READY
                    end
                end
            end

            # The jobs currently running on {#app}'s plan
            #
            # @return [Hash<Integer,(Symbol,Roby::Task,Roby::Task)>] the mapping
            #   from job ID to the job's state (as returned by {job_state}), the
            #   placeholder job task and the job task itself
            def jobs
                result = Hash.new
                engine.execute do
                    planning_tasks = plan.find_tasks(Job).to_a
                    planning_tasks.each do |job_task|
                        job_id = job_task.job_id
                        next if !job_id
                        placeholder_job_task = job_task.planned_task || job_task
                        result[job_id] = [job_state(placeholder_job_task), placeholder_job_task, job_task]
                    end
                end
                result
            end
            command :jobs, 'returns the list of non-finished jobs'

            def find_job_info_by_id(id)
                engine.execute do
                    if planning_task = plan.find_tasks(Job).with_arguments(job_id: id).to_a.first
                        task = planning_task.planned_task || planning_task
                        return job_state(task), task, planning_task
                    end
                end
            end

            # Finds a job task by its ID
            #
            # @param [Integer] id
            # @return [Roby::Task,nil]
            def find_job_by_id(id)
                engine.execute do
                    return plan.find_tasks(Job).with_arguments(:job_id => id).to_a.first
                end
            end

            # Finds the task that represents the given job ID
            #
            # It can be different than the job task when e.g. the job task is a
            # planning task
            def find_job_placeholder_by_id(id)
                if task = find_job_by_id(id)
                    return task.planned_task || task
                end
            end

            # Reload all models from this Roby application
            #
            # Do NOT do this while the robot does critical things
            def reload_models
                engine.execute do
                    app.reload_models
                end
                nil
            end

            # @deprecated use {#reload_actions} instead
            def reload_planners
                reload_actions
            end

            # Reload the actions defined under the actions/ subfolder
            def reload_actions
                engine.execute do
                    app.reload_actions
                end
                actions
            end
            command :reload_actions, 'reloads the files in models/actions/'

            # (see ExecutionEngine#on_exception)
            def on_exception(&block)
                engine.execute do
                    engine.on_exception(&block)
                end
            end

            # @see ExecutionEngine#remove_exception_listener
            def remove_exception_listener(listener)
                engine.execute do
                    engine.remove_exception_listener(listener)
                end
            end

            # This is implemented on ShellClient directly
            command 'describe', 'gives details about the given action',
                :action => 'the action itself'

            # This is implemented on Server directly
            command 'enable_notifications', 'enables the forwarding of notifications'
            command 'disable_notifications', 'disables the forwarding of notifications'
        end
    end
end


