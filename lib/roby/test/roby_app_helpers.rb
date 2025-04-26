# frozen_string_literal: true

module Roby
    module Test
        # Helpers to test a full Roby app started as a subprocess
        module RobyAppHelpers
            attr_reader :app, :app_dir

            def setup
                @roby_app_interface_version ||= 1
                @roby_plugin_path = []

                require "roby/interface/v#{@roby_app_interface_version}"

                @spawned_pids = []
                super
                @app = Roby::Application.new
                app.public_logs = false
                app.plugins_enabled = false
                @app_dir = make_tmpdir
                app.app_dir = app_dir
                register_plan(@app.plan)
            end

            def teardown
                app.stop_log_server
                app.stop_shell_interface
                app.cleanup
                kill_spawned_pids
                super
            end

            def kill_spawned_pids(
                pids = @spawned_pids.map(&:pid),
                signal: "INT", next_signal: "KILL", timeout: 5
            )
                pending_children = pids.find_all do |pid|
                    begin
                        Process.kill signal, pid
                        true
                    rescue Errno::ESRCH # rubocop:disable Lint/SuppressedException
                    end
                end

                deadline = Time.now + timeout
                while Time.now < deadline
                    pending_children.delete_if do |pid|
                        Process.waitpid2(pid, Process::WNOHANG)
                    end
                    return if pending_children.empty?

                    sleep 0.01
                end

                return if pending_children.empty?

                flunk("failed to stop #{pending_children}") unless next_signal

                kill_spawned_pids(pending_children, signal: next_signal, next_signal: nil)
            end

            def gen_app(app_dir = self.app_dir)
                require "roby/cli/gen_main"
                Dir.chdir(app_dir) { CLI::GenMain.start(["app", "--quiet"]) }
            end

            def roby_bin
                File.expand_path(
                    File.join("..", "..", "..", "bin", "roby"),
                    __dir__
                )
            end

            def roby_app_with_polling(timeout: 2, period: 0.01, message: nil)
                start_time = Time.now
                while (Time.now - start_time) < timeout
                    if (result = yield)
                        return result
                    end

                    sleep period
                end
                if message
                    flunk "#{message} did not happen within #{timeout} seconds"
                else
                    flunk "failed to reach expected result within #{timeout} seconds"
                end
            end

            def roby_app_interface_module(version: @roby_app_interface_version)
                require "roby/interface/v#{version}"

                if version == 1
                    Roby::Interface::V1
                elsif version == 2
                    Roby::Interface::V2
                else
                    raise ArgumentError, "invalid interface version #{version}"
                end
            end

            def assert_roby_app_is_running(
                pid, timeout: 20, host: "localhost", port: Interface::DEFAULT_PORT
            )
                start_time = Time.now
                while (Time.now - start_time) < timeout
                    if ::Process.waitpid(pid, Process::WNOHANG)
                        if (captured_output = roby_app_join_capture_thread(pid))
                            flunk "Roby app unexpectedly quit\n" \
                                  "stdout=#{captured_output[:out]}\n" \
                                  "stderr=#{captured_output[:err]}"
                        else
                            flunk "Roby app unexpectedly quit"
                        end
                    end

                    begin
                        return roby_app_interface_module.connect_with_tcp_to(host, port)
                    rescue Roby::Interface::ConnectionError # rubocop:disable Lint/SuppressedException
                    end
                    sleep 0.01
                end
                flunk "could not get a connection within #{timeout} seconds"
            end

            # Call the `quit` command and wait for the app to exit
            #
            # @see assert_roby_app_exits
            def assert_roby_app_quits(pid, port: Interface::DEFAULT_PORT, interface: nil)
                interface_owned = !interface
                interface ||= assert_roby_app_is_running(pid, port: port)
                interface.quit
                assert_roby_app_exits(pid)
            ensure
                interface&.close if interface_owned
            end

            # Wait for a subprocess to exit
            def assert_process_exits(pid, timeout: 20)
                deadline = Time.now + timeout
                while Time.now < deadline
                    _, status = Process.waitpid2(pid, Process::WNOHANG)
                    if status
                        roby_app_join_capture_thread(pid)
                        return status
                    end

                    sleep 0.01
                end

                if (output = roby_app_captured_output(pid))
                    flunk(
                        "process #{pid} did not quit within #{timeout} seconds\n" \
                        "stdout=#{output[:out]}\n" \
                        "stderr=#{output[:err]}"
                    )
                else
                    flunk("process #{pid} did not quit within #{timeout} seconds")
                end
            end

            # Wait for the app to exit
            #
            # Unlike {#assert_roby_app_quits}, this method does not explicitly
            # call quit or send a SIGINT signal. The app is expected to quit by
            # itself
            #
            # @see assert_roby_app_quits
            def assert_roby_app_exits(pid, timeout: 20)
                assert_process_exits(pid, timeout: timeout)
            end

            # Return the output captured so far for the given PID
            #
            # If the process has stopped and {#roby_app_quit} or {#assert_roby_app_exits}
            # was called, the output is complete. Otherwise it might be partial
            #
            # @return [nil,{out: String, err: String}] nil if the PID does not exist,
            #   or if roby_app_spawn was not configured to capture the output. Otherwise,
            #   a hash with the stdout and stderr strings
            def roby_app_captured_output(pid)
                return unless (spawned = @spawned_pids.find { |p| p.pid == pid })
                return unless (queue = spawned.capture_queue)

                outputs = spawned.captured_output
                until queue.empty?
                    output, string = queue.pop
                    outputs[output] << string
                end

                outputs.transform_values! { |arr| [arr.join] }
                outputs.transform_values(&:first)
            end

            def assert_roby_app_has_job(
                interface, action_name, timeout: 2, state: Interface::JOB_STARTED
            )
                start_time = Time.now
                while (Time.now - start_time) < timeout
                    jobs = interface.find_all_jobs_by_action_name(action_name)
                    jobs = jobs.find_all { |j| j.state == state } if state
                    if (j = jobs.first)
                        return j
                    end

                    sleep 0.01
                end
                flunk "timed out while waiting for action #{action_name} on #{interface}"
            end

            def roby_app_join_capture_thread(pid)
                return unless (spawned = @spawned_pids.find { |p| p.pid == pid })
                return unless (thread = spawned.capture_thread)

                thread.join
                roby_app_captured_output(pid)
            end

            def roby_app_quit(interface, timeout: 2)
                _, status = Process.waitpid2(pid)
                roby_app_join_capture_thread(pid)

                return if status.success?

                raise "roby app with PID #{pid} exited with nonzero status"
            end

            # Path to the app test fixtures, that is test/app/fixtures
            def roby_app_fixture_path
                File.expand_path(
                    File.join("..", "..", "..", "test", "app", "fixtures"),
                    __dir__
                )
            end

            # Create a minimal Roby application with a given list of scripts copied
            # in scripts/
            #
            # @param [String] scripts list of scripts, relative to
            #    {#roby_app_fixture_path}
            # @return [String] the path to the app root
            def roby_app_setup_single_script(*scripts)
                dir = make_tmpdir
                FileUtils.mkdir_p File.join(dir, "config", "robots")
                FileUtils.mkdir_p File.join(dir, "scripts")
                FileUtils.touch File.join(dir, "config", "app.yml")
                FileUtils.touch File.join(dir, "config", "robots", "default.rb")
                scripts.each do |p|
                    p = File.expand_path(p, roby_app_fixture_path)
                    FileUtils.cp p, File.join(dir, "scripts")
                end
                dir
            end

            def roby_app_allocate_port
                server = TCPServer.new(0)
                server.local_address.ip_port
            ensure
                server&.close
            end

            def roby_app_allocate_interface_port
                roby_app_allocate_port
            end

            ROBY_PORT_COMMANDS = %w[run].freeze
            ROBY_NO_INTERFACE_COMMANDS = %w[wait check test].freeze

            def register_roby_plugin(path)
                @roby_plugin_path << path
            end

            SpawnedProcess = Struct.new(
                :pid, :capture_thread, :capture_queue, :captured_output,
                keyword_init: true
            )

            # @api private
            #
            # Start thread that pull data out of a process output pipes
            def roby_app_spawn_output_capture_thread(out_r, err_r, queue)
                ios = [out_r, err_r]
                Thread.new do
                    until ios.empty?
                        with_events, = select(ios, [], [])
                        with_events.each do |io|
                            unless (data = io.read_nonblock(4096))
                                raise EOFError
                            end

                            queue.push([io == out_r ? :out : :err, data])
                        rescue EOFError
                            ios.delete(io)
                            io.close
                        rescue IO::WaitReadable
                            # Wait for more data
                        end
                    end
                end
            end

            # @api private
            #
            # Helper to determine the "right" interface-related arguments in
            # {#roby_app_spawn}
            def roby_app_spawn_interface_args(command, port)
                port ||= roby_app_allocate_port
                if ROBY_PORT_COMMANDS.include?(command)
                    ["--interface-versions=#{@roby_app_interface_version}",
                     "--port-v#{@roby_app_interface_version}", port.to_s]
                elsif !ROBY_NO_INTERFACE_COMMANDS.include?(command)
                    ["--interface-version=#{@roby_app_interface_version}",
                     "--host", "localhost:#{port}"]
                end
            end

            # Spawn the roby app process
            #
            # @return [Integer] the app PID
            def roby_app_spawn( # rubocop:disable Metrics/ParameterLists
                command, *args,
                port: nil, capture_output: false, silent: false, env: {}, **options
            )
                if capture_output
                    out_r, out_w = IO.pipe
                    err_r, err_w = IO.pipe
                    capture_queue = Queue.new
                    capture_thread = roby_app_spawn_output_capture_thread(
                        out_r, err_r, capture_queue
                    )
                    options[:out] = out_w
                    options[:err] = err_w
                elsif silent
                    options[:out] ||= "/dev/null"
                    options[:err] ||= "/dev/null"
                end

                port_args = roby_app_spawn_interface_args(command, port)
                pid = spawn(
                    { "ROBY_PLUGIN_PATH" => @roby_plugin_path.join(":") }.merge(env),
                    roby_bin, command, *port_args, *args, chdir: app_dir, **options
                )
                out_w&.close
                err_w&.close
                @spawned_pids << SpawnedProcess.new(
                    pid: pid,
                    capture_thread: capture_thread,
                    capture_queue: capture_queue,
                    captured_output: { out: [], err: [] }
                )
                pid
            end

            # Start the roby app, and wait for it to be ready
            #
            # @return [(Integer,Roby::Interface::Client)] the app PID and connected
            #   roby interface
            def roby_app_start(*args, port: nil, silent: false, **options)
                port ||= roby_app_allocate_port
                pid = roby_app_spawn(*args, port: port, silent: silent, **options)
                interface = assert_roby_app_is_running(pid, port: port)
                [pid, interface]
            end

            def register_pid(pid)
                @spawned_pids << SpawnedProcess.new(pid: pid)
            end

            def roby_app_run(*args, port: nil, silent: false, **options)
                pid = roby_app_spawn(*args, port: port, silent: silent, **options)
                assert_roby_app_exits(pid)
            end

            def roby_app_create_logfile
                require "roby/droby/logfile/writer"
                logfile_dir = make_tmpdir
                logfile_path = File.join(logfile_dir, "logfile")
                writer = DRoby::Logfile::Writer.open(logfile_path)
                [logfile_path, writer]
            end

            # Contact a remote interface and perform some action(s)
            #
            # The method disconnects from the interface before returning
            #
            # @yieldparam [Roby::Interface::Client] client the interface client
            # @yieldreturn [Object] object returned by the method
            def roby_app_call_remote_interface(
                host: "localhost", port: Interface::DEFAULT_PORT
            )
                interface = roby_app_interface_module.connect_with_tcp_to(host, port)
                yield(interface) if block_given?
            ensure
                interface&.close
            end

            def roby_app_shell_interface(version: @roby_app_interface_version)
                if version == 1
                    app.shell_interface
                else
                    app.shell_interface_v2
                end
            end

            # Create a client to the interface running in the test's current app
            #
            # The method disconnects from the interface before returning
            #
            # @yieldparam [Roby::Interface::Client] client the interface client
            # @yieldreturn [Object] object returned by the method
            def roby_app_call_interface(
                version: @roby_app_interface_version,
                host: "localhost", port: Interface::DEFAULT_PORT
            )
                client_thread = Thread.new do
                    begin
                        interface =
                            roby_app_interface_module(version: version)
                            .connect_with_tcp_to(host, port)
                        result = yield(interface) if block_given?
                    rescue Exception => e # rubocop:disable Lint/RescueException
                        error = e
                    end
                    [interface, result, error]
                end
                while client_thread.alive?
                    roby_app_shell_interface(version: version)
                        .process_pending_requests
                end
                begin
                    interface, result, error = client_thread.value
                rescue Exception => e # rubocop:disable Lint/RescueException
                    raise e, e.message, e.backtrace + caller
                end
                interface.close
                raise error if error

                result
            end

            def assert_roby_app_can_connect_to_log_server(
                timeout: 2, port: app.log_server_port
            )
                client = roby_app_with_polling(
                    timeout: timeout,
                    message: "connecting to the log server on port #{port}"
                ) do
                    begin
                        DRoby::Logfile::Client.new("localhost", port)
                    rescue Interface::ConnectionError # rubocop:disable Lint/SuppressedException
                    end
                end
                client.read_and_process_pending until client.init_done?
            rescue StandardError
                # Give time to the log server to report errors before we
                # terminate it with SIGINT
                sleep 0.1
                raise
            ensure
                client&.close
            end

            def app_helpers_source_dir(source_dir)
                @helpers_source_dir = source_dir
            end

            def copy_into_app(template, target = template)
                FileUtils.mkdir_p File.join(app_dir, File.dirname(target))
                FileUtils.cp File.join(@helpers_source_dir, template),
                             File.join(app_dir, target)
            end
        end
    end
end
