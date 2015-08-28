module Roby
    module Interface
        module Async
            # An event-based client to for the Roby interface
            #
            # This class provides an asynchronous (event-based) API to the Roby
            # interface, it allows for job and task discovery and tracking, and
            # is robust to disconnections and reconnections.
            #
            # It is meant for the implementations of GUIs that interface with a
            # Roby system. The {#poll} method must be called regularly from a
            # main event loop (e.g. from a Qt timer)
            #
            # Notification callbacks can be registered with one of the on_
            # methods (on_job, ...). A Qt-oriented declarative approach to
            # binding jobs to a UI can be found in {UIConnector}
            class Interface < BasicObject
                extend Logger::Hierarchy
                extend Logger::Forward

                include Hooks
                include Hooks::InstanceHooks

                # @return [String] a string that describes the remote host
                attr_reader :remote_name
                # @return [#call] an object that can create a Client instance
                attr_reader :connection_method
                # @return [Client,nil] the socket used to communicate to the server,
                #   or nil if we have not managed to connect yet
                attr_reader :client
                # The future used to connect to the remote process without blocking
                # the main event loop
                attr_reader :connection_future

                # @!group Hooks

                # @!method on_reachable()
                #   Hooks called when we successfully connected
                #
                #   @param [Array<JobMonitor>] list of currently active jobs, as
                #     returned by {#jobs}
                #   @return [void]
                define_hooks :on_reachable
                # @!method on_unreachable()
                #
                #   Hooks called when we got disconnected
                #   @return [void]
                define_hooks :on_unreachable
                # @!method on_notification
                #
                #   Hooks called for generic notifications
                #
                #   @yieldparam [Symbol] level message level
                #   @yieldparam [String] message a text message explaining the
                #     notification
                #   @return [void]
                define_hooks :on_notification
                # @!method on_job_progress
                #
                #   Hooks called for job progress notifications
                #
                #   @yieldparam [Symbol] state the new job state, as one of the
                #     JOB constants defined on {Roby::Interface}
                #   @yieldparam [Integer] job_id the job ID
                #   @yieldparam [String] job_name the job name
                #   @yieldparam [Array<Object>] args additional information
                #     specific to this progress message
                #   @return [void]
                define_hooks :on_job_progress
                # @!method on_exception
                #
                #   Hooks called for exceptions
                #
                #   @yieldparam (see Roby::Interface::Interface#on_exception)
                #   @return [void]
                define_hooks :on_exception

                # Registers a callback that should be called for each new job
                #
                # The callback gets called, on registration, with all the
                # existing jobs. It is then called with new jobs as they get
                # created.
                #
                # @param [String,nil] action_name limit notifications to actions
                #   with this name. No filtering is performed if nil.
                # @yieldparam [JobMonitor] job_monitor a monitor for a job that is just
                #   created. It is not monitoring the job yet, call
                #   {JobMonitor#start} to get it to start monitoring.
                # @return [NewJobListener]
                def on_job(action_name: nil, jobs: jobs, &block)
                    listener = NewJobListener.new(self, action_name, block)
                    listener.start
                    if reachable?
                        run_initial_new_job_hooks_events(listener, self.jobs)
                    end
                    listener
                end


                # @!endgroup Hooks

                # The set of JobMonitor objects currently registered on self
                #
                # @return [Hash<Integer,Set<JobMonitor>>]
                attr_reader :job_monitors

                # The set of NewJobListener objects currently registered on self
                #
                # @return [Array<NewJobListener>]
                attr_reader :new_job_listeners

                DEFAULT_REMOTE_NAME = "localhost"

                def initialize(remote_name = DEFAULT_REMOTE_NAME, connect: true, &connection_method)
                    @connection_method = connection_method || lambda {
                        Roby::Interface.connect_with_tcp_to('localhost', Distributed::DEFAULT_DROBY_PORT)
                    }

                    @remote_name = remote_name
                    @first_connection_attempt = true
                    if connect
                        attempt_connection
                    end

                    @job_monitors = Hash.new
                    @new_job_listeners = Array.new
                end

                # Start a connection attempt
                def attempt_connection
                    @connection_future = Concurrent::Future.new do
                        client = connection_method.call
                        [client, client.jobs]
                    end
                    connection_future.execute
                end

                # The set of known actions
                #
                # This is available only after we got a successful connection to
                # the remote side
                def actions
                    client.actions
                end

                # Verify the state of the last connection attempt
                #
                # It checks on the last connection attempt, and sets {#client}
                # if it was successful, as well as call the callbacks registered
                # with {#on_reachable}
                def poll_connection_attempt
                    return if client

                    if connection_future.complete?
                        case e = connection_future.reason
                        when ConnectionError, ComError
                            Interface.info "failed connection attempt: #{e}"
                            attempt_connection
                            if @first_connection_attempt
                                @first_connection_attempt = false
                                run_hook :on_unreachable
                            end
                            nil
                        when NilClass
                            Interface.info "successfully connected"
                            @client, jobs = connection_future.value
                            jobs = jobs.map do |job_id, (job_state, placeholder_task, job_task)|
                                JobMonitor.new(self, job_id, state: job_state, placeholder_task: placeholder_task, task: job_task)
                            end
                            run_hook :on_reachable, jobs
                            new_job_listeners.each do |listener|
                                listener.reset
                                run_initial_new_job_hooks_events(listener, jobs)
                            end
                        else
                            raise connection_future.reason
                        end
                    end
                end

                # @private
                #
                # Process the message queues from {#client}
                def process_message_queues
                    client.notification_queue.each do |id, level, message|
                        run_hook :on_notification, level, message
                    end
                    client.notification_queue.clear

                    client.job_progress_queue.each do |id, (job_state, job_id, job_name, *args)|
                        new_job_listeners.each do |listener|
                            if listener.seen_job_with_id?(job_id)
                                job =
                                    if job_state == JOB_MONITORED
                                        JobMonitor.new(
                                            self, job_id,
                                            state: job_state,
                                            placeholder_task: args[0],
                                            task: args[1])
                                    else
                                        monitor_job(job_id, start: false)
                                    end
                                if listener.matches?(job)
                                    listener.call(job)
                                end
                            end
                        end

                        if monitors = job_monitors[job_id]
                            monitors.each do |m|
                                m.update_state(job_state)
                                if job_state == JOB_REPLACED
                                    m.replaced(args.first)
                                end
                            end
                        end
                        run_hook :on_job_progress, job_state, job_id, job_name, args
                    end
                    client.job_progress_queue.clear

                    client.exception_queue.each do |id, (kind, exception, tasks, job_ids)|
                        job_ids.each do |job_id|
                            if monitors = job_monitors[job_id]
                                monitors.dup.each do |m|
                                    m.notify_exception(kind, exception)
                                end
                            end
                        end

                        run_hook :on_exception, kind, exception, tasks, job_ids
                    end
                    client.exception_queue.clear
                end

                def connected?
                    !!client
                end

                # Active part of the async. This has to be called regularly within
                # the system's main event loop (e.g. Roby's, Vizkit's or Qt's)
                #
                # @return [Boolean] true if we are connected to the remote server
                #   and false otherwise
                def poll
                    if connected?
                        _, has_cycle_end = client.poll
                        process_message_queues
                        if has_cycle_end
                            cleanup_dead_monitors
                        end
                        true
                    else
                        poll_connection_attempt
                        !!client
                    end
                rescue ComError
                    Interface.info "link closed, trying to reconnect"
                    unreachable!
                    attempt_connection
                    false
                rescue Exception => e
                    Interface.warn "error while polling connection, trying to reconnect"
                    Roby.log_exception_with_backtrace(e, Interface, :warn)
                    unreachable!
                    attempt_connection
                    false
                end

                def unreachable!
                    job_monitors.each_value do |monitors|
                        monitors.each do |j|
                            j.update_state(:finalized)
                        end
                    end
                    job_monitors.clear

                    if client
                        client.close if !client.closed?
                        @client = nil
                        run_hook :on_unreachable
                    end
                end

                def close
                    unreachable!
                end

                # True if we are connected to a client
                def reachable?
                    !!client
                end

                # Returns all the existing jobs on this interface
                #
                # The returned monitors are not started, you have to call
                # {JobMonitor#start} explicitely on them before you use them
                #
                # @return [Array<JobMonitor>]
                def jobs
                    return Array.new if !reachable?

                    client.jobs.map do |job_id, (job_state, placeholder_task, job_task)|
                        JobMonitor.new(self, job_id, placeholder_task: placeholder_task, task: job_task, state: job_state)
                    end
                end

                # Find the jobs that have been created from a given action
                #
                # The returned monitors are not started, you have to call
                # {JobMonitor#start} explicitely on them before you use them
                #
                # @param [String] action_name the action name
                # @return [Array<JobMonitor>] the matching jobs
                def find_all_jobs(action_name, jobs: jobs)
                    jobs.find_all do |job|
                        job.task.action_model.name == action_name
                    end
                end

                # Create a monitor on a job based on its ID
                #
                # The monitor is already started
                def monitor_job(job_id, start: true)
                    job_state, placeholder_task, job_task = client.find_job_info_by_id(job_id)
                    job = JobMonitor.new(self, job_id, state: job_state, placeholder_task: placeholder_task, task: job_task)
                    if start
                        job.start
                    end
                    job
                end

                # @api private
                #
                # Helper to call a job listener for all matching jobs in a job
                # set. This is called when the new job listener is created and
                # when we get connected to a roby interface
                #
                # @param [NewJobListener] listener
                # @param [Array<JobMonitor>] jobs
                def run_initial_new_job_hooks_events(listener, jobs = self.jobs)
                    jobs.each do |job|
                        if listener.matches?(job)
                            listener.call(job)
                        end
                    end
                end

                def create_batch(&block)
                    client.create_batch(&block)
                end

                def add_new_job_listener(job)
                    new_job_listeners << job
                end

                def remove_new_job_listener(job)
                    new_job_listeners.delete(job)
                end

                def add_job_monitor(job)
                    set = (job_monitors[job.job_id] ||= Set.new)
                    job_monitors[job.job_id] << job
                end

                def cleanup_dead_monitors
                    job_monitors.delete_if do |job_id, monitors|
                        monitors.delete_if do |job|
                            job.finalized?
                        end
                        monitors.empty?
                    end
                end

                def remove_job_monitor(job)
                    set = job_monitors[job.job_id]
                    set.delete(job)
                    if set.empty?
                        job_monitors.delete(job.job_id)
                    end
                end

                def connect_to_ui(widget, &block)
                    UIConnector.new(self, widget).instance_eval(&block)
                end
            end
        end
    end
end

