# frozen_string_literal: true

require "aruba/api"

module Roby
    module Test
        # Minitest-usable Aruba wrapper
        #
        # Aruba 0.14 is incompatible with Minitest because of their definition
        # of the #run method This change hacks around the problem, by moving
        # the Aruba API to a side stub object.
        #
        # The run methods are renamed as they have been renamed in Aruba 1.0
        # alpha, run -> run_command and run_simple -> run_command_and_stop
        module ArubaMinitest
            # A "api-only" class that includes the Aruba API module
            #
            # Aruba's API is implemented with modules, but is self-contained.
            # Create an object we can delegate to. This was needed because Aruba
            # defined #run, which is also a minitest method (this is not the case
            # anymore, but this lingers)
            class API
                include ::Aruba::Api
            end

            attr_reader :roby_bin

            def setup
                super
                @aruba_api = API.new
                @aruba_api.setup_aruba
                @roby_bin = File.join(Roby::BIN_DIR, "roby")
            end

            def teardown
                stop_all_commands
                super
            end

            def roby_allocate_port
                server = ::TCPServer.new(0)
                server.local_address.ip_port
            ensure
                server&.close
            end

            def run_command_and_stop(*args, fail_on_error: true)
                cmd = run_command(*args)
                cmd.stop
                assert_command_finished_successfully(cmd) if fail_on_error
                cmd
            end

            def run_command(*args)
                @aruba_api.run_command(*args)
            end

            def run_roby_and_stop(cmd, *args, fail_on_error: true, **opts)
                run_command_and_stop("#{Gem.ruby} #{roby_bin} #{cmd}", *args,
                                     fail_on_error: fail_on_error, **opts)
            end

            def run_roby(cmd, *args, fail_on_error: true, **opts)
                run_command("#{Gem.ruby} #{roby_bin} #{cmd}", *args,
                            fail_on_error: fail_on_error, **opts)
            end

            def respond_to_missing?(name, include_private = false)
                @aruba_api.respond_to?(name) || super
            end

            def method_missing(name, *args, &block)
                if @aruba_api.respond_to?(name)
                    return @aruba_api.send(name, *args, &block)
                end

                super
            end

            def assert_command_stops(cmd, fail_on_error: true)
                cmd.stop
                assert_command_finished_successfully(cmd) if fail_on_error
            end

            def assert_command_finished_successfully(cmd)
                refute cmd.timed_out?,
                       "#{cmd} timed out on stop\n-- STDOUT\n#{cmd.stdout}\n"\
                       "STDERR\n#{cmd.stderr}"
                assert_equal 0, cmd.exit_status,
                             "#{cmd} finished with a non-zero exit status "\
                             "(#{cmd.exit_status})\n-- STDOUT\n#{cmd.stdout}\n"\
                             "-- STDERR\n#{cmd.stderr}"
            end

            def wait_for_output(cmd, channel, timeout: 5)
                deadline = Time.now + timeout
                while Time.now < deadline
                    if yield(cmd.send(channel))
                        assert(true) # To account for the assertion
                        return
                    end
                end

                flunk("timed out waiting for #{channel} to match in #{cmd}")
            end
        end
    end
end
