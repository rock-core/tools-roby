module Roby
    module Test
        # Helpers to test a full Roby app started as a subprocess
        module RobyAppHelpers
            def setup
                @spawned_pids = Array.new
                super
            end

            def teardown
                super
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
            end

            def roby_bin
                File.expand_path(
                    File.join("..", "..", "..", 'bin', 'roby'),
                    __dir__)
            end

            def roby_app_with_polling(timeout: 2, period: 0.01)
                start_time = Time.now
                while (Time.now - start_time) < timeout
                    return if yield
                    sleep 0.01
                end
            end

            def assert_roby_app_is_running(pid, timeout: 2, host: 'localhost', port: Roby::Interface::DEFAULT_PORT)
                start_time = Time.now
                while (Time.now - start_time) < timeout
                    begin
                        return Roby::Interface.connect_with_tcp_to(host, port)
                    rescue Roby::Interface::ConnectionError
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

            def assert_roby_app_has_job(interface, action_name, timeout: 2, state: Interface::JOB_STARTED)
                start_time = Time.now
                while (Time.now - start_time) < timeout
                    jobs = interface.find_all_jobs_by_action_name(action_name)
                    if state
                        jobs = jobs.find_all { |j| j.state == state }
                    end
                    if j = jobs.first
                        return j
                    end
                    sleep 0.01
                end
                flunk "timed out while waiting for action #{action_name} on #{interface}"
            end

            def roby_app_quit(interface, timeout: 2)
                _, status = Process.waitpid2(pid)
                if !status.success?
                    raise "roby app with PID #{pid} exited with nonzero status"
                end
            end

            def roby_app_fixture_path
                File.expand_path(
                    File.join("..", "..", "..", 'test', "app", "fixtures"),
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

            def roby_app_spawn(*args, **options)
                pid = spawn(roby_bin, *args, **options)
                @spawned_pids << pid
                return pid
            end
        end
    end
end

