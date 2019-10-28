module Roby
    module Test
        # Helpers to test a full Roby app started as a subprocess
        module RobyAppHelpers
            attr_reader :app, :app_dir

            def setup
                @spawned_pids = Array.new
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
                pending_children = @spawned_pids.find_all do |pid|
                    begin
                        Process.kill 'INT', pid
                        true
                    rescue Errno::ESRCH
                    end
                end

                pending_children.each do |pid|
                    Process.waitpid2(pid)
                end
                super
            end

            def gen_app(app_dir = self.app_dir)
                require 'roby/cli/gen_main'
                Dir.chdir(app_dir) { CLI::GenMain.start(['app', '--quiet']) }
            end

            def roby_bin
                File.expand_path(
                    File.join("..", "..", "..", 'bin', 'roby'),
                    __dir__)
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

            def assert_roby_app_is_running(pid, timeout: 10, host: 'localhost',
                                           port: Roby::Interface::DEFAULT_PORT)
                start_time = Time.now
                while (Time.now - start_time) < timeout
                    if ::Process.waitpid(pid, Process::WNOHANG)
                        flunk 'Roby app unexpectedly quit'
                    end

                    begin
                        return Roby::Interface.connect_with_tcp_to(host, port)
                    rescue Roby::Interface::ConnectionError # rubocop:disable Lint/HandleExceptions
                    end
                    sleep 0.01
                end
                flunk "could not get a connection within #{timeout} seconds"
            end

            def assert_roby_app_quits(pid, interface: nil)
                interface ||= assert_roby_app_is_running(pid)
                interface.quit
                _, status = Process.waitpid2(pid)
                assert status.exited?
                assert_equal 0, status.exitstatus
            end

            def assert_roby_app_has_job(interface, action_name, timeout: 2,
                                        state: Interface::JOB_STARTED)
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

            def roby_app_quit(interface, timeout: 2)
                _, status = Process.waitpid2(pid)
                return if status.success?

                raise "roby app with PID #{pid} exited with nonzero status"
            end

            def roby_app_fixture_path
                File.expand_path(
                    File.join('..', '..', '..', 'test', 'app', 'fixtures'),
                    __dir__)
            end

            def roby_app_setup_single_script(*scripts)
                dir = make_tmpdir
                FileUtils.mkdir_p File.join(dir, 'config', 'robots')
                FileUtils.mkdir_p File.join(dir, 'scripts')
                FileUtils.touch File.join(dir, 'config', 'app.yml')
                FileUtils.touch File.join(dir, 'config', 'robots', 'default.rb')
                scripts.each do |p|
                    p = File.expand_path(p, roby_app_fixture_path)
                    FileUtils.cp p, File.join(dir, 'scripts')
                end
                return dir
            end

            def roby_app_spawn(*args, silent: false, **options)
                if silent
                    options[:out] ||= '/dev/null'
                    options[:err] ||= '/dev/null'
                end
                pid = spawn(roby_bin, *args, chdir: app_dir, **options)
                @spawned_pids << pid
                pid
            end

            def roby_app_create_logfile
                require 'roby/droby/logfile/writer'
                logfile_dir = make_tmpdir
                logfile_path = File.join(logfile_dir, 'logfile')
                writer = DRoby::Logfile::Writer.open(logfile_path)
                [logfile_path, writer]
            end

            # Contact a remote interface and perform some action(s)
            #
            # The method disconnects from the interface before returning
            #
            # @yieldparam [Roby::Interface::Client] client the interface client
            # @yieldreturn [Object] object returned by the method
            def roby_app_call_remote_interface(host: 'localhost',
                                               port: Interface::DEFAULT_PORT)
                interface = Interface.connect_with_tcp_to(host, port)
                yield(interface) if block_given?
            ensure
                interface&.close
            end

            # Create a client to the interface running in the test's current app
            #
            # The method disconnects from the interface before returning
            #
            # @yieldparam [Roby::Interface::Client] client the interface client
            # @yieldreturn [Object] object returned by the method
            def roby_app_call_interface(host: 'localhost', port: Interface::DEFAULT_PORT)
                client_thread = Thread.new do
                    begin
                        interface = Interface.connect_with_tcp_to(host, port)
                        result = yield(interface) if block_given?
                    rescue Exception => e # rubocop:disable Lint/RescueException
                        error = e
                    end
                    [interface, result, error]
                end
                app.shell_interface.process_pending_requests while client_thread.alive?
                begin
                    interface, result, error = client_thread.value
                rescue Exception => e # rubocop:disable Lint/RescueException
                    raise e, e.message, e.backtrace + caller
                end
                interface.close
                raise error if error

                result
            end

            def assert_roby_app_can_connect_to_log_server(timeout: 2,
                                                          port: app.log_server_port)
                client = roby_app_with_polling(
                    timeout: timeout,
                    message: "connecting to the log server on port #{port}"
                ) do
                    begin
                        DRoby::Logfile::Client.new('localhost', port)
                    rescue Interface::ConnectionError # rubocop:disable Lint/HandleExceptions
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

