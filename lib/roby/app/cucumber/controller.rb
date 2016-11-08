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

                # Whether this started a Roby controller
                def roby_running?
                    !!@roby_pid
                end

                # Whether we have a connection to the started Roby controller
                def roby_connected?
                    roby_interface.connected?
                end

                def initialize(port: Roby::Interface::DEFAULT_PORT)
                    @roby_pid = nil
                    @roby_interface = Roby::Interface::Async::Interface.
                        new('localhost', port: port)
                    @background_jobs = Array.new
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
                def roby_start(robot_name, robot_type, connect: true, controller: true, app_dir: Dir.pwd, state: Hash.new)
                    if roby_running?
                        raise InvalidState, "a Roby controller is already running, call #roby_stop and #roby_join first"
                    end

                    @roby_pid = spawn Gem.ruby, '-S', 'roby', 'run',
                        "--robot=#{robot_name},#{robot_type}",
                        '--quiet',
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

                # Start a job in the background
                #
                # Its failure will make the next #run_job step fail. Unlike a
                # job created by {#start_monitoring_job}, it will not be stopped
                # when {#run_job} is called.
                def start_job(description, m, arguments = Hash.new)
                    action = Interface::Async::ActionMonitor.new(roby_interface, m, arguments)
                    action.restart
                    background_jobs << BackgroundJob.new(action, description, false)
                    action
                end

                # Start a background action whose failure will make the next
                # #run_job step fail
                #
                # This action will be stopped at the end of the next {#run_job}
                def start_monitoring_job(description, m, arguments = Hash.new)
                    action = Interface::Async::ActionMonitor.new(roby_interface, m, arguments)
                    action.restart
                    background_jobs << BackgroundJob.new(action, description, true)
                    action
                end

                # Find one monitoring job that failed
                def find_failed_background_job
                    background_jobs.find do |a|
                        a.action_monitor.terminated? && !a.action_monitor.success?
                    end
                end

                # Start an action
                def run_job(m, arguments = Hash.new)
                    action = Interface::Async::ActionMonitor.new(roby_interface, m, arguments)
                    action.restart
                    while !action.async
                        roby_interface.poll
                        roby_interface.wait
                    end

                    while !action.terminated? && !(failed_monitor = find_failed_background_job)
                        if defined?(::Cucumber) && ::Cucumber.wants_to_quit
                            raise Interrupt, "Interrupted"
                        end
                        roby_interface.poll
                        roby_interface.wait
                    end

                    if action.success?
                        return
                    elsif failed_monitor
                        raise FailedBackgroundJob, "monitoring job #{failed_monitor.description} failed"
                    else
                        raise FailedAction, "action #{m} failed"
                    end

                ensure
                    # Kill the monitoring actions as well as the main actions
                    drop_monitoring_jobs(action)
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
