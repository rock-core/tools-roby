require 'minitest'
require "drb"
require "tmpdir"
require 'roby/hooks'
require 'roby/droby'

module Roby
    module App
        class Minitest::UnexpectedError
            def droby_dump(peer = nil)
                result = dup
                result.exception = exception.droby_dump(peer)
                result
            end

            def proxy(manager)
                result = dup
                result.exception = manager.local_object(result.exception)
                result
            end

            def pretty_print(pp)
                exception.pretty_print(pp)
            end
        end

        # DRuby server for a client/server scheme in autotest
        #
        # The client side is implemented in {TestReporter}
        #
        # Note that the idea and a big chunk of the implementation has been
        # taken from the minitest-server plugin. The main differences is that it
        # accounts for load errors (exceptions that happen outside of minitest
        # itself) and is using DRoby's marshalling for exceptions
        class TestServer
            def self.path(pid = Process.pid)
                "drbunix:#{Dir.tmpdir}/minitest.#{pid}"
            end

            include Hooks
            include Hooks::InstanceHooks

            # @!method on_exception
            #
            # Hook called when an exception has been caught by Autorespawn
            #
            # @yieldparam [Integer] pid the client PID
            # @yieldparam [Exception] exception
            define_hooks :on_exception

            # @!method on_discovery_start
            #
            # Hook called when a discovery process starts
            #
            # @yieldparam [Integer] pid the client PID
            define_hooks :on_discovery_start

            # @!method on_discovery_finished
            #
            # Hook called when a discovery process finishes
            #
            # @yieldparam [Integer] pid the client PID
            # @yieldparam [Hash] id the test ID
            define_hooks :on_discovery_finished

            # @!method on_test_start
            #
            # Hook called when a test starts
            #
            # @yieldparam [Integer] pid the client PID
            define_hooks :on_test_start

            # @!method on_test_method
            #
            # Hook called when a test method starts its execution
            #
            # @yieldparam [Integer] pid the client PID
            # @yieldparam [String] file the file containing the test
            # @yieldparam [String] test_case_name the test case name
            # @yieldparam [String] test_name the test name
            define_hooks :on_test_method

            # @!method on_test_result
            #
            # Hook called when a test has been executed
            #
            # @yieldparam [Integer] pid the client PID
            # @yieldparam [String] file the file containing the test
            # @yieldparam [String] test_case_name the test case name
            # @yieldparam [String] test_name the test name
            # @yieldparam [Array<Minitest::Assertion>] failures the list of test failures
            # @yieldparam [Integer] assertions the number of assertions
            # @yieldparam [Time] time the time spent running the test
            define_hooks :on_test_result

            # @!method on_test_finished
            #
            # Hook called when a test finished
            #
            # @yieldparam [Integer] pid the client PID
            define_hooks :on_test_finished

            # A value that allows to identify this server uniquely
            #
            # Usually the server PID
            attr_reader :server_id

            # The autorespawn manager
            #
            # @return [Autorespawn::Manager]
            attr_reader :manager

            def self.start(id)
                server = new(id)
                DRb.start_service path, server
                server
            end

            def self.stop
                DRb.stop_service
            end

            def initialize(server_id, manager = DRoby::Marshal.new(auto_create_plans: true))
                @server_id = server_id
                @manager = manager
            end

            def discovery_start(pid)
                run_hook :on_discovery_start, pid
            end

            def discovery_finished(pid)
                run_hook :on_discovery_finished, pid
            end

            def exception(pid, e)
                run_hook :on_exception, pid, manager.local_object(e)
            end

            def test_start(pid)
                run_hook :on_test_start, pid
            end

            def test_method(pid, file, klass, method)
                run_hook :on_test_method, pid, file, klass, method
            end

            def test_result(pid, file, klass, method, fails, assertions, time)
                run_hook :on_test_result, pid, file, klass, method,
                    manager.local_object(fails), assertions, time
            end

            def test_finished(pid)
                run_hook :on_test_finished, pid
            end
        end
    end
end

