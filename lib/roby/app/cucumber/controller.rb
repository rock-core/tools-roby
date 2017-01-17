require 'roby/interface/async'

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

                # The object used to communicate with the Roby instance
                #
                # It is set only after {#roby_wait} was called (or after a
                # {#roby_start} whose wait parameter was set to true)
                #
                # @return [Roby::Interface::Client,nil]
                attr_reader :roby_interface

                # The set of jobs started by {#start_monitoring_job}
                attr_reader :background_jobs

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
                    !!@roby_pid
                end

                # Whether we have a connection to the started Roby controller
                def roby_connected?
                    roby_interface.connected?
                end

                def initialize(port: Roby::Interface::DEFAULT_PORT,
                               keep_running: (ENV['CUCUMBER_KEEP_RUNNING'] == '1'),
                               validation_mode: (ENV['ROBY_VALIDATE_STEPS'] == '1'))
                    @roby_pid = nil
                    @roby_interface = Roby::Interface::Async::Interface.
                        new('localhost', port: port)
                    @background_jobs = Array.new
                    @keep_running = keep_running
                    @validation_mode = validation_mode
                    @last_main_job_id = nil
                end

                # Start a Roby controller
                # 
                # @param [String] robot_name the name of the robot configuration
                # @param [String] robot_type the type of the robot configuration
                # @param [Boolean] wait whether the method should wait for a
                #   successful connection to the Roby application
                # @param [Boolean] controller whether the configuration's controller
                #   blocks should be executed
                # @param [Hash] state initial values for the state
                #
                # @raise InvalidState if a controller is already running
                def roby_start(robot_name, robot_type, connect: true, controller: true, app_dir: Dir.pwd, log_dir: nil, state: Hash.new)
                    if roby_running?
                        raise InvalidState, "a Roby controller is already running, call #roby_stop and #roby_join first"
                    end

                    options = Array.new
                    if log_dir
                        options << "--log-dir=#{log_dir}"
                    end
                    @roby_pid = spawn Gem.ruby, '-S', 'roby', 'run',
                        "--robot=#{robot_name},#{robot_type}",
                        '--controller',
                        '--quiet',
                        *options,
                        *state.map { |k, v| "--set=#{k}=#{v}" },
                        chdir: app_dir,
                        pgroup: 0
                    if connect
                        roby_connect
                    end
                    roby_pid
                end

                # Try connecting to the Roby controller
                #
                # It sets {#roby_interface} on success
                #
                # @return [Roby::Interface::Client,nil] a valid interface object
                #   if the connection was successful, and nil otherwise
                def roby_try_connect
                    if !roby_interface.connecting? && !roby_interface.connected?
                        roby_interface.attempt_connection
                    end
                    roby_interface.poll
                    roby_interface.connected?
                end

                # Wait for the Roby controller started with {#roby_start} to be
                # available
                def roby_connect
                    if roby_connected?
                        raise InvalidState, "already connected"
                    end

                    while !roby_connected?
                        roby_try_connect
                        _, status = Process.waitpid2(roby_pid, Process::WNOHANG)
                        if status
                            raise InvalidState, "remote Roby controller quit before we could get a connection"
                        end
                        roby_interface.wait
                    end
                end

                # Disconnect the interface to the controller, but does not stop
                # the controller
                def roby_disconnect
                    if !roby_connected?
                        raise InvalidState, "not connected"
                    end

                    @roby_interface.close
                end

                # Stops an already started Roby controller
                #
                # @raise InvalidState if no controllers were started
                def roby_stop(join: true)
                    if !roby_running?
                        raise InvalidState, "cannot call #roby_stop if no controllers were started"
                    elsif !roby_connected?
                        raise InvalidState, "you need to successfully connect to the Roby controller with #roby_connect before you can call #roby_stop"
                    end

                    begin
                        roby_interface.quit
                    rescue Interface::ComError
                    ensure
                        roby_interface.close
                    end

                    roby_join if join
                end

                # Kill the Roby controller process
                def roby_kill(join: true)
                    if !roby_running?
                        raise InvalidState, "cannot call #roby_stop if no controllers were started"
                    end

                    Process.kill('INT', roby_pid)
                    roby_join if join
                end


                # Wait for the remote process to quit
                def roby_join
                    if !roby_running?
                        raise InvalidState, "cannot call #roby_join without a running Roby controller"
                    end

                    _, status = Process.waitpid2(roby_pid)
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
                    if !roby_connected?
                        raise InvalidState, "you need to successfully connect to the Roby controller with #roby_connect before you can call #roby_enable_backtrace_filtering"
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
                    def monitoring?
                        monitoring
                    end
                end

                attr_reader :last_main_job_id

                # Start a job in the background
                #
                # Its failure will make the next #run_job step fail. Unlike a
                # job created by {#start_monitoring_job}, it will not be stopped
                # when {#run_job} is called.
                def start_job(description, m, arguments = Hash.new)
                    action = __start_job(description, m, arguments, false)
                    if !validation_mode?
                        roby_poll_interface_until { action.async }
                        @last_main_job_id = action.job_id
                    end
                    action
                end

                # Start a background action whose failure will make the next
                # #run_job step fail
                #
                # This action will be stopped at the end of the next {#run_job}
                def start_monitoring_job(description, m, arguments = Hash.new)
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

                    action = Interface::Async::ActionMonitor.new(roby_interface, m, arguments)
                    action.restart
                    background_jobs << BackgroundJob.new(action, description, monitoring)
                    action
                end

                # Enumerate all jobs started with {#start_monitoring_job}
                def each_monitoring_job
                    return enum_for(__method__) if !block_given?
                    background_jobs.each do |job|
                        yield(job.action_monitor) if job.monitoring
                    end
                end

                # Enumerate all jobs started with {#start_job}
                #
                # These jobs are usually the job-under-test, hence the 'main'
                # moniker
                def each_main_job
                    return enum_for(__method__) if !block_given?
                    background_jobs.each do |job|
                        yield(job.action_monitor) if !job.monitoring
                    end
                end

                # Find one monitoring job that failed
                def find_failed_background_job
                    background_jobs.find do |a|
                        a.action_monitor.terminated? && !a.action_monitor.success?
                    end
                end

                # @api private
                #
                # Poll the interface until the block returns a truthy value
                def roby_poll_interface_until
                    while !(result = yield)
                        if defined?(::Cucumber) && ::Cucumber.wants_to_quit
                            raise Interrupt, "Interrupted"
                        end
                        roby_interface.poll
                        roby_interface.wait
                    end
                    result
                end

                # Start an action
                def run_job(m, arguments = Hash.new)
                    if validation_mode?
                        validate_job(m, arguments)
                        return
                    end

                    action = Interface::Async::ActionMonitor.new(roby_interface, m, arguments)
                    action.restart
                    roby_poll_interface_until { action.async }
                    failed_monitor = roby_poll_interface_until do
                        if action.terminated?
                            break
                        else
                            find_failed_background_job
                        end
                    end

                    if action.success?
                        return
                    elsif failed_monitor
                        if keep_running?
                            STDERR.puts
                            STDERR.puts "FAILED: monitoring job #{failed_monitor.description} failed"
                            STDERR.puts "In 'keep running' mode. Interrupt with CTRL+C"
                            roby_poll_interface_until { false }
                        else
                            raise FailedBackgroundJob, "monitoring job #{failed_monitor.description} failed"
                        end
                    else
                        if keep_running?
                            STDERR.puts
                            STDERR.puts "FAILED: action #{m} failed"
                            STDERR.puts "In 'keep running' mode. Interrupt with CTRL+C"
                            roby_poll_interface_until { false }
                        else
                            raise FailedAction, "action #{m} failed"
                        end
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
                    if !(action = roby_interface.client.find_action_by_name(m))
                        raise InvalidJob, "no action is named '#{m}'"
                    end
                    arguments = arguments.dup
                    action.arguments.each do |arg|
                        arg_sym = arg.name.to_sym
                        has_arg = arguments.has_key?(arg_sym)
                        if !has_arg && arg.required?
                            raise InvalidJob, "#{m} requires an argument named #{arg.name} which is not provided"
                        end
                        arguments.delete(arg_sym)
                    end
                    if !arguments.empty?
                        raise InvalidJob, "arguments #{arguments.keys.map(&:to_s).sort.join(", ")} are not declared arguments of #{m}"
                    end
                end

                def drop_all_jobs(*extra_jobs)
                    jobs, @background_jobs =
                        background_jobs, Array.new
                    drop_jobs(*extra_jobs, *jobs.map(&:action_monitor))
                end

                def drop_monitoring_jobs(*extra_jobs)
                    monitoring_jobs, @background_jobs =
                        background_jobs.partition { |j| j.monitoring? }
                    drop_jobs(*extra_jobs, *monitoring_jobs.map(&:action_monitor))
                end

                def drop_jobs(*jobs)
                    batch = roby_interface.create_batch
                    jobs.each do |act|
                        if !act.terminated? && act.async
                            act.drop(batch: batch)
                        end
                    end
                    batch.__process
                    @monitoring_jobs = Array.new
                    @main_jobs = Array.new
                end
            end
        end
    end
end
