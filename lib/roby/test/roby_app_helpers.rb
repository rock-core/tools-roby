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
                @spawned_pids.each do |pid|
                    begin Process.kill 'KILL', pid
                    rescue Errno::ESRCH
                    end
                end
            end

            def roby_bin
                File.expand_path(
                    File.join("..", "..", "..", 'bin', 'roby'),
                    __dir__)
            end

            def wait_for_roby_app(pid, timeout: 2, host: 'localhost', port: Roby::Interface::DEFAULT_PORT)
                start_time = Time.now
                while (Time.now - start_time) < timeout
                    begin
                        return Roby::Interface.connect_with_tcp_to(host, port)
                    rescue Roby::Interface::ConnectionError
                    end
                end
                raise RuntimeError, "could not get a connection within #{timeout} seconds"
            end

            def wait_and_quit_roby_app(pid, timeout: 2)
                wait_for_roby_app(pid, timeout: timeout).quit
                _, status = Process.waitpid2(pid)
                if !status.success?
                    raise "roby app with PID #{pid} exited with nonzero status"
                end
            end

            def spawn(*args, **options)
                pid = super
                @spawned_pids << pid
                pid
            end
        end
    end
end

