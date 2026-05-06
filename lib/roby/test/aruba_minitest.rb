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
                @interface_server&.close
                stop_all_commands
                super
            end

            def run_roby_environment
                { "ROBY_PLUGIN_PATH" => @roby_plugin_path.join(":") }
            end

            # Create a TCPServer to be used as the underlying's `roby run` server
            #
            # @return [Integer] the file descriptor number to be passed to --interface-fd
            def roby_allocate_interface_server
                raise "interface server already allocated" if @interface_server

                @interface_server = ::TCPServer.new(0)
                @interface_server.fileno
            end

            # Port of the interface server allocated with
            # {#roby_allocate_interface_server}
            def roby_interface_port
                @interface_server.local_address.ip_port
            end

            def roby_allocate_port
                server = ::TCPServer.new(0)
                server.local_address.ip_port
            ensure
                server&.close
            end

            def run_command_and_stop(cmd, fail_on_error: true, exit_timeout: 45, **opts)
                opts[:exit_timeout] ||= exit_timeout
                cmd = run_command(cmd, **opts)
                cmd.stop
                assert_command_finished_successfully(cmd) if fail_on_error
                cmd
            end

            def run_command(cmd, exit_timeout: 45, **opts)
                opts[:exit_timeout] ||= exit_timeout
                @aruba_api.run_command(cmd, opts)
            end

            # Run a subcommand of the `roby` CLI and wait for it to stop
            #
            # @param [String] cmd the command (e.g. quit --retry)
            # @return [Aruba::Command] the aruba command object
            def run_roby_and_stop(
                cmd, *args, fail_on_error: true, exit_timeout: 45, **opts
            )
                opts[:exit_timeout] ||= exit_timeout
                run_command_and_stop("#{Gem.ruby} #{roby_bin} #{cmd}", *args,
                                     fail_on_error: fail_on_error, **opts)
            end

            # Run a subcommand of the `roby` CLI
            #
            # @param [String] cmd the command (e.g. quit --retry)
            # @return [Aruba::Command] the aruba command object
            def run_roby(cmd, fail_on_error: true, exit_timeout: 45, **opts)
                opts[:exit_timeout] ||= exit_timeout
                run_command("#{Gem.ruby} #{roby_bin} #{cmd}",
                            fail_on_error: fail_on_error, **opts)
            end

            # Run `roby run`
            #
            # Unlike calling `run_roby` directly, it sets up the --interface-fd argument
            # properly if {#roby_allocate_interface_server} has been called
            def run_roby_run(cmd = "", interface_version: 1, forwarded_ios: [], **opts)
                if @interface_server
                    arg =
                        if interface_version == 1
                            "--interface-fd"
                        else
                            "--interface-v2-fd"
                        end

                    cmd = "--interface-versions=#{interface_version} " \
                          "#{arg}=#{@interface_server.fileno} #{cmd}"

                    forwarded_ios += [@interface_server.fileno]
                end

                run_roby("run #{cmd}", forwarded_ios: forwarded_ios, **opts)
            end

            # @api private
            #
            # Command line arguments to connect to a Roby instance
            def roby_client_args(interface_version)
                "--host=localhost:#{roby_interface_port} " \
                    "--interface-version=#{interface_version}"
            end

            # Run a Roby CLI command that requires to connect to a Roby instance
            #
            # The command expects the interface itself to have been generated using
            # {#roby_allocate_interface_server}
            def run_roby_client(cmd, *args, interface_version: 1, **opts)
                run_roby("#{cmd} #{roby_client_args(interface_version)}", *args, **opts)
            end

            # Run a Roby CLI command that requires to connect to a Roby instance, and
            # wait for it to stop
            #
            # The command expects the interface itself to have been generated using
            # {#roby_allocate_interface_server}
            def run_roby_client_and_stop(cmd, *args, interface_version: 1, **opts)
                run_roby_and_stop(
                    "#{cmd} #{roby_client_args(interface_version)}", *args, **opts
                )
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
