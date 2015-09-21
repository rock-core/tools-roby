require 'roby/app/test_server'

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

            def initialize(pid, slave_name, server_pid, manager: Distributed::DumbManager)
                @pid = pid
                @slave_name = slave_name
                uri = TestServer.path(server_pid)
                @server = DRbObject.new_with_uri uri
                @manager = manager
                super()
            end

            def exception(e)
                server.exception(pid, Distributed.format(e, manager))
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

            # This method is part of the minitest API ... cannot change its name
            def record(result)
                r = result
                c = r.class
                file, = c.instance_method(r.name).source_location
                failures = Distributed.format(r.failures, manager)
                server.test_result(pid, file, c.name, r.name, failures, r.assertions, r.time)
            end

            def test_finished
                server.test_finished(pid)
            end
        end
    end
end

