# frozen_string_literal: true

require "roby/app/test_server"

module Roby
    module App
        # Minitest reporter for a client/server scheme in autotest
        #
        # Note that the idea and a big chunk of the implementation has been
        # taken from the minitest-server plugin. The main differences is that it
        # accounts for load errors (exceptions that happen outside of minitest
        # itself) and is using DRoby's marshalling for exceptions
        class TestReporter
            attr_reader :pid
            attr_reader :slave_name
            attr_reader :server
            attr_reader :manager

            # Whether some failures were reported
            attr_predicate :has_failures?

            def initialize(pid, slave_name, server_pid, manager: DRoby::Marshal.new)
                @pid = pid
                @slave_name = slave_name
                uri = TestServer.path(server_pid)
                @server = DRbObject.new_with_uri uri
                @manager = manager
                super()
            end

            def exception(e)
                @has_failures = true
                server.exception(pid, manager.dump(e))
            end

            def discovery_start
                server.discovery_start(pid)
            end

            def discovery_finished
                server.discovery_finished(pid)
            end

            def test_start
                server.test_start(pid)
            end

            # This method is part of the minitest API
            def prerecord(klass, method_name)
                file, = klass.instance_method(method_name).source_location
                server.test_method(pid, file, klass.name, method_name)
            end

            # This method is part of the minitest API ... cannot change its name
            def record(result)
                r = result
                if r.respond_to?(:source_location) # Minitest 3.11+
                    class_name = r.klass
                    file, = r.source_location
                else
                    c = r.class
                    file, = c.instance_method(r.name).source_location
                    class_name = c.name
                end
                failures = manager.dump(r.failures)
                @has_failures ||= r.failures.any? { |e| !e.kind_of?(Minitest::Skip) }
                server.test_result(pid, file, class_name, r.name, failures, r.assertions, r.time)
            end

            def test_finished
                server.test_finished(pid)
            end
        end
    end
end
