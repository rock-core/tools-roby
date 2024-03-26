# frozen_string_literal: true

require "roby/interface/v1/async"

module Roby
    module App
        module Cucumber
            # API that starts and communicates with a Roby controller for the
            # benefit of a Cucumber scenario
            class Controller
                class InvalidState < RuntimeError; end

                # The PID of the started Roby process
                #
                # @return [Integer,nil]
                attr_reader :roby_pid

                # The set of jobs started by {#start_monitoring_job}
                attr_reader :background_jobs

                # The batch that gathers all the interface operations that will
                # be executed at the next #run_job
                attr_reader :current_batch

                # Actions that would be started by {#current_batch}
                attr_reader :pending_actions

                # Whether the process should abort when an error is detected, or
                # keep running the actions as-is. The latter is useful for
                # debugging
                #
                # Active the keep running mode by setting CUCUMBER_KEEP_RUNNING
                # to 1
                attr_predicate :keep_running?, true

                # Whether we run the jobs, or only validate their existence and
                # arguments
                #
                # The validation mode is activated by setting
                # ROBY_VALIDATE_STEPS to '1'
                attr_predicate :validation_mode?, true

                # Whether this started a Roby controller
                def roby_running?
                    @roby_pid
                end

                # Whether we have a connection to the started Roby controller
                def roby_connected?
                    @roby_interface&.connected?
                end

                # @param [Integer] port the port through which we should connect
                #   to the Roby interface. Set to zero to pick a random port.
                def initialize(
                    port: Roby::Interface::DEFAULT_PORT,
                    keep_running: (ENV["CUCUMBER_KEEP_RUNNING"] == "1"),
                    validation_mode: (ENV["ROBY_VALIDATE_STEPS"] == "1")
                )
                    @roby_pid = nil
                    @roby_port = port
                    @background_jobs = []
                    @keep_running = keep_running
                    @validation_mode = validation_mode
                    @pending_actions = []
                end

                # The object used to communicate with the Roby instance
                #
                # @return [Roby::Interface::V1::Async::Interface]
                def roby_interface
                    if @roby_port == 0
                        raise InvalidState,
                              "you passed port: 0 to .new, but has not yet "\
                              "called #roby_start"
                    end

                    @roby_interface ||=
                        Roby::Interface::V1::Async::Interface
                        .new("localhost", port: @roby_port)
                end

                # Start a Roby controller
                #
                # @param [String] robot_name the name of the robot configuration
                # @param [String] robot_type the type of the robot configuration
                # @param [Boolean] controller whether the configuration's controller
                #   blocks should be executed
                # @param [Hash] state initial values for the state
                # @option [Boolean] wait whether the method should wait for a
                #   successful connection to the Roby application
                #
                # @raise InvalidState if a controller is already running
                def roby_start(
                    robot_name, robot_type,
                    connect: true, controller: true, app_dir: Dir.pwd,
                    log_dir: nil, state: {}, **spawn_options
                )
                    if roby_running?
                        raise InvalidState,
                              "a Roby controller is already running, "\
                              "call #roby_stop and #roby_join first"
                    end

                    options = []
                    options << "--log-dir=#{log_dir}" if log_dir
                    if @roby_port == 0
                        server = TCPServer.new("localhost", 0)
                        options << "--interface-fd=#{server.fileno}"
                        spawn_options = spawn_options.merge({ server => server })
                        @roby_port = server.local_address.ip_port
                    else
                        options << "--port=#{@roby_port}"
                    end
                    @roby_pid = spawn(
                        Gem.ruby, File.join(Roby::BIN_DIR, "roby"), "run",
                        "--robot=#{robot_name},#{robot_type}",
                        "--controller",
                        "--quiet",
                        *options,
                        *state.map { |k, v| "--set=#{k}=#{v}" },
                        chdir: app_dir,
                        pgroup: 0,
                        **spawn_options
                    )
                    server&.close
                    roby_connect if connect
                    roby_pid
                end

                # Try connecting to the Roby controller
                #
                # @return [Boolean] true if the interface is connected, false otherwise
                def roby_try_connect
                    # If in auto-port mode, we can't connect until roby_start
                    # has been called
                    return if @roby_port == 0

                    if !roby_interface.connecting? && !roby_interface.connected?
                        roby_interface.attempt_connection
                    end
                    roby_interface.poll
                    roby_interface.connected?
                end

                class ConnectionTimeout < RuntimeError
                end

                # Wait for the Roby controller started with {#roby_start} to be
                # available
                def roby_connect(timeout: 20)
                    raise InvalidState, "already connected" if roby_connected?

                    deadline = Time.now + timeout

                    until roby_connected?
                        roby_try_connect
                        _, status = Process.waitpid2(roby_pid, Process::WNOHANG)
                        if status
                            raise InvalidState,
                                  "remote Roby controller quit before "\
                                  "we could get a connection"
                        end
                        roby_interface.wait(timeout: timeout / 10)

                        if Time.now > deadline
                            raise ConnectionTimeout,
                                  "failed to connect to a Roby controller in less than "\
                                  "#{timeout}s"
                        end
                    end
                    @current_batch = @roby_interface.create_batch
                end

                # Disconnect the interface to the controller, but does not stop
                # the controller
                def roby_disconnect
                    raise InvalidState, "not connected" unless roby_connected?

                    @roby_interface.close
                end

                class JoinTimedOut < RuntimeError
                end

                # Stops an already started Roby controller
                #
                # @raise InvalidState if no controllers were started
                def roby_stop(join: true, join_timeout: 5)
                    if !roby_running?
                        raise InvalidState,
                              "cannot call #roby_stop if no controllers were started"
                    elsif !roby_connected?
                        raise InvalidState,
                              "you need to successfully connect to the Roby "\
                              "controller with #roby_connect before you can call "\
                              "#roby_stop"
                    end

                    begin
                        roby_interface.quit
                    rescue Interface::ComError
                        puts "QUIT FAILED"
                    ensure
                        roby_interface.close
                    end
                    return unless join

                    roby_join_or_kill(join_timeout: join_timeout,
                                      signal: "INT", next_signal: "KILL")
                end

                # Kill the Roby controller process
                def roby_kill(join: true, join_timeout: 5, signal: "INT")
                    unless roby_running?
                        raise InvalidState,
                              "cannot call #roby_kill if no controllers were started"
                    end

                    Process.kill(signal, roby_pid)
                    return unless join

                    roby_join_or_kill(join_timeout: join_timeout,
                                      signal: "INT", next_signal: "KILL")
                end

                def roby_join_or_kill(join_timeout: 5, signal: "INT", next_signal: signal)
                    roby_join(timeout: join_timeout)
                rescue JoinTimedOut
                    STDERR.puts "timed out while waiting for a Roby controller to stop"
                    STDERR.puts "trying the #{signal} signal"
                    roby_kill(signal: signal, join: false)
                    roby_join_or_kill(join_timeout: join_timeout, signal: next_signal)
                end

                # Wait for the remote process to quit
                def roby_join(timeout: nil)
                    unless roby_running?
                        raise InvalidState,
                              "cannot call #roby_join without a running Roby controller"
                    end

                    status = nil
                    if timeout
                        deadline = Time.now + timeout
                        loop do
                            _, status = Process.waitpid2(roby_pid, Process::WNOHANG)
                            break if status

                            sleep 0.1
                            if Time.now > deadline
                                raise JoinTimedOut,
                                      "roby_join timed out waiting for end of "\
                                      "PID #{roby_pid}"
                            end
                        end
                    else
                        _, status = Process.waitpid2(roby_pid)
                    end
                    @roby_pid = nil
                    status
                rescue Errno::ECHILD
                    @roby_pid = nil
                end

                # Wait for the remote process to quit
                #
                # It raises an exception if the process does not terminate
                # successfully
                def roby_join!
                    if (status = roby_join) && !status.success?
                        raise InvalidState, "Roby process exited with status #{status}"
                    end
                rescue Errno::ENOCHILD
                    @roby_pid = nil
                end

                # Enable or disable backtrace filtering on the Roby instance
                def roby_enable_backtrace_filtering(enable: true)
                    unless roby_connected?
                        raise InvalidState,
                              "you need to successfully connect to the Roby "\
                              "controller with #roby_connect before you can call "\
                              "#roby_enable_backtrace_filtering"
                    end
                    roby_interface.client.enable_backtrace_filtering(enable: enable)
                end

                # The log dir of the Roby app
                #
                # Since the roby app is local, this is a valid local path
                def roby_log_dir
                    roby_interface.client.log_dir
                end

                # Exception raised when an monitor failed while an action was
                # running
                class FailedBackgroundJob < RuntimeError; end

                # Exception raised when an action finished with any other state
                # than 'success'
                class FailedAction < RuntimeError; end

                BackgroundJob = Struct.new :action_monitor, :description, :monitoring do
                    def job_id
                        action_monitor.job_id
                    end

                    def success?
                        action_monitor.success?
                    end

                    def terminated?
                        action_monitor.terminated?
                    end

                    def monitoring?
                        monitoring
                    end
                end

                # The job ID of the last started
                #
                # @return [nil,Integer] nil if the job has not yet been started,
                #   and the ID otherwise. It's the caller responsibility to call
                #   {#apply_current_batch}
                def last_main_job_id
                    each_main_job.to_a.last&.job_id
                end

                # Start a job in the background
                #
                # Its failure will make the next #run_job step fail. Unlike a
                # job created by {#start_monitoring_job}, it will not be stopped
                # when {#run_job} is called.
                def start_job(description, m, arguments = {})
                    if @has_run_job
                        drop_all_jobs unless validation_mode?
                        @has_run_job = false
                    end
                    __start_job(description, m, arguments, false)
                end

                # Start a background action whose failure will make the next
                # #run_job step fail
                #
                # This action will be stopped at the end of the next {#run_job}
                def start_monitoring_job(description, m, arguments = {})
                    __start_job(description, m, arguments, true)
                end

                # @api private
                #
                # Helper job-starting method
                def __start_job(description, m, arguments, monitoring)
                    if validation_mode?
                        validate_job(m, arguments)
                        return
                    end

                    action = Interface::V1::Async::ActionMonitor.new(
                        roby_interface, m, arguments
                    )
                    action.restart(batch: current_batch)
                    pending_actions << action
                    background_jobs << BackgroundJob.new(action, description, monitoring)
                    action
                end

                # Enumerate all jobs started with {#start_monitoring_job}
                def each_monitoring_job
                    return enum_for(__method__) unless block_given?

                    background_jobs.each do |job|
                        yield(job) if job.monitoring?
                    end
                end

                # Enumerate all jobs started with {#start_job}
                #
                # These jobs are usually the job-under-test, hence the 'main'
                # moniker
                def each_main_job
                    return enum_for(__method__) unless block_given?

                    background_jobs.each do |job|
                        yield(job) unless job.monitoring?
                    end
                end

                # Find one monitoring job that failed
                def find_failed_monitoring_job
                    each_monitoring_job.find do |background_job|
                        background_job.terminated? && !background_job.success?
                    end
                end

                # @api private
                #
                # Poll the interface until the block returns a truthy value
                def roby_poll_interface_until
                    until (result = yield)
                        if defined?(::Cucumber) &&
                           ::Cucumber.respond_to?(:wants_to_quit) &&
                           ::Cucumber.wants_to_quit
                            raise Interrupt, "Interrupted"
                        end

                        roby_interface.poll
                        roby_interface.wait
                    end
                    result
                end

                def apply_current_batch(*actions, sync: true)
                    return if current_batch.empty?

                    batch_result = current_batch.__process
                    if sync
                        roby_poll_interface_until do
                            (pending_actions + actions).all?(&:async)
                        end
                    end
                    batch_result
                ensure
                    @current_batch = roby_interface.create_batch
                    @pending_actions = []
                end

                # Start an action
                def run_job(m, arguments = {})
                    if validation_mode?
                        validate_job(m, arguments)
                        return
                    end

                    action = Interface::V1::Async::ActionMonitor.new(
                        roby_interface, m, arguments
                    )
                    action.restart(batch: current_batch)
                    apply_current_batch(action)
                    @has_run_job = true

                    failed_monitor = roby_poll_interface_until do
                        break if action.terminated?

                        find_failed_monitoring_job
                    end

                    return if action.success?

                    if failed_monitor
                        if keep_running?
                            STDERR.puts <<~MESSAGE

                                FAILED: monitoring job #{failed_monitor.description} failed
                                In 'keep running' mode. Interrupt with CTRL+C
                            MESSAGE
                            roby_poll_interface_until { false }
                        else
                            raise FailedBackgroundJob,
                                  "monitoring job #{failed_monitor.description} failed"
                        end
                    elsif keep_running?
                        STDERR.puts <<~MESSAGE

                            FAILED: action #{m} failed"
                            In 'keep running' mode. Interrupt with CTRL+C"
                        MESSAGE
                        roby_poll_interface_until { false }
                    else
                        raise FailedAction, "action #{m} failed"
                    end
                ensure
                    # Kill the monitoring actions as well as the main actions
                    drop_monitoring_jobs(*Array(action))
                end

                # Raised when validating the jobs
                class InvalidJob < ArgumentError; end

                # @api private
                #
                # Validate that the given action name and arguments match the
                # interface's description
                def validate_job(m, arguments)
                    unless (action = roby_interface.client.find_action_by_name(m))
                        raise InvalidJob, "no action is named '#{m}'"
                    end

                    arguments = arguments.dup
                    action.arguments.each do |arg|
                        arg_sym = arg.name.to_sym
                        has_arg = arguments.key?(arg_sym)
                        if !has_arg && arg.required?
                            raise InvalidJob,
                                  "#{m} requires an argument named #{arg.name} "\
                                  "which is not provided"
                        end
                        arguments.delete(arg_sym)
                    end
                    return if arguments.empty?

                    raise InvalidJob,
                          "arguments #{arguments.keys.map(&:to_s).sort.join(', ')} "\
                          "are not declared arguments of #{m}"
                end

                def drop_all_jobs(*extra_jobs)
                    jobs = @background_jobs
                    @background_jobs = []
                    drop_jobs(*extra_jobs, *jobs.map(&:action_monitor))
                end

                def drop_monitoring_jobs(*extra_jobs)
                    monitoring_jobs, @background_jobs =
                        background_jobs.partition(&:monitoring?)
                    drop_jobs(*extra_jobs, *monitoring_jobs.map(&:action_monitor))
                end

                def drop_jobs(*jobs)
                    jobs.each do |act|
                        act.drop(batch: current_batch) if !act.terminated? && act.async
                    end
                end
            end
        end
    end
end
