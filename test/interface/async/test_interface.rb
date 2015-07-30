require 'roby/test/self'
require 'roby/interface/async'
require 'roby/interface/tcp'

Concurrent.disable_at_exit_handlers!

module Roby
    module Interface
        module Async
            describe Interface do
                attr_reader :recorder
                before do
                    @recorder = flexmock
                    @interfaces = Array.new
                    @interface_servers = Array.new
                end
                after do
                    @interfaces.each(&:close)
                    @interface_servers.each(&:close)
                end

                def create_server
                    server = Roby::Interface::TCPServer.new(Roby.app, Distributed::DEFAULT_DROBY_PORT)
                    @interface_servers << server
                    server
                end

                def create_client(*args, **options, &block)
                    interface = Interface.new(*args, **options, &block)
                    @interfaces << interface
                    interface
                end

                def connect(server = nil, *args, **options, &block)
                    server ||= create_server
                    client = create_client(*args, **options)
                    yield(client) if block_given?
                    while !client.connection_future.complete?
                        server.process_pending_requests
                    end
                    client.poll
                    client
                end

                def process_call(&block)
                    futures = [Concurrent::Future.new(&block),
                               Concurrent::Future.new { @interfaces.each(&:poll) }]
                    result = futures.map do |future|
                        future.execute
                        while !future.complete?
                            @interface_servers.each do |s|
                                s.process_pending_requests
                                s.clients.each(&:poll)
                            end
                            Thread.pass
                        end
                        future.value
                    end
                    result.first
                end

                describe "reachability hooks" do
                    it "calls on_unreachable once when there are no remote server" do
                        interface = connect
                        recorder.should_receive(:reachable).never
                        interface.on_reachable { recorder.reachable }
                        recorder.should_receive(:unreachable).once
                        interface.on_unreachable { recorder.unreachable }
                        interface.connection_future.wait
                        interface.poll
                        interface.poll
                    end
                    it "calls on_reachable callback when connected to the remote server" do
                        server    = create_server
                        interface = create_client
                        recorder.should_receive(:reachable).once.ordered
                        interface.on_reachable { recorder.reachable }
                        # The unreachable event will be received on teardown
                        recorder.should_receive(:unreachable).once.ordered
                        interface.on_unreachable { recorder.unreachable }
                        while !interface.connection_future.complete?
                            server.process_pending_requests
                        end
                        interface.poll
                        interface.poll
                    end
                    it "passes the current list of jobs as argument to #on_reachable" do
                        server = create_server
                        flexmock(server.interface).should_receive(:jobs).and_return(1 => ['a', 'b', 'c'])
                        recorder.should_receive(:called).
                            once.
                            with(lambda { |jobs| jobs.size == 1 &&
                                   jobs.first.job_id == 1 &&
                                   jobs.first.state == 'a' &&
                                   jobs.first.task == 'c' })
                        client = connect(server) do |c|
                            c.on_reachable { |jobs| recorder.called(jobs) }
                        end
                    end
                    it "calls the on_unreachable callback when the connection is lost" do
                        server = create_server
                        client = connect(server)
                        recorder.should_receive(:unreachable).once.ordered
                        recorder.should_receive(:done).once.ordered
                        client.on_unreachable { recorder.unreachable }
                        server.close
                        client.poll
                        recorder.done
                    end
                end

                describe "#jobs" do
                    it "returns an empty array if not reachable" do
                        client = create_client
                        assert_equal [], client.jobs
                    end
                    it "returns the current list of jobs" do
                        server = create_server
                        client = connect(server)
                        flexmock(server.interface).should_receive(:jobs).and_return(1 => ['a', 'b', 'c'])
                        jobs = process_call { client.jobs }
                        assert_equal 1, jobs.size
                        job = jobs.first
                        assert_equal 1, job.job_id
                        assert_equal 'a', job.state
                        assert_equal 'c', job.task
                    end
                end

                describe "#on_job" do
                    it "calls the hook on the current jobs" do
                        server = create_server
                        client = connect(server)
                        flexmock(server.interface).should_receive(:jobs).and_return(1 => ['a', 'b', 'c'])
                        recorder.should_receive(:job).
                            once.
                            with(lambda { |job|
                                   job.job_id == 1 &&
                                   job.state == 'a' &&
                                   job.task == 'c' })
                        process_call do
                            client.on_job { |j| recorder.job(j) }
                        end
                    end
                    it "calls the hook on the jobs received at connection time" do
                        client = create_client(connect: false)
                        recorder.should_receive(:job).
                            once.
                            with(lambda { |job| 
                                   job.job_id == 1 &&
                                   job.state == 'a' &&
                                   job.task == 'c' })
                        client.on_job { |j| recorder.job(j) }

                        server = create_server
                        flexmock(server.interface).should_receive(:jobs).and_return(1 => ['a', 'b', 'c'])

                        future = client.attempt_connection
                        process_call { future.wait }
                    end

                    describe "new jobs" do
                        attr_reader :server, :client

                        before do
                            @server = create_server
                            @client = connect(server)
                            recorder.should_receive(:job).
                                once.
                                with(lambda { |job| 
                                       job.job_id == 1 &&
                                       job.state == 'a' &&
                                       job.task == 'c' })
                            process_call do
                                client.on_job { |j| recorder.job(j) }
                            end
                            flexmock(server.interface).should_receive(:find_job_info_by_id).
                                with(1).
                                and_return(['a', 'b', 'c'])
                        end

                        it "calls the hook on jobs created by a third party" do
                            server.interface.job_notify(Roby::Interface::JOB_READY, 1, 'name')
                            process_call { client.poll }
                        end
                        it "does not call the hook on jobs that have already been seen" do
                            server.interface.job_notify(Roby::Interface::JOB_READY, 1, 'name')
                            server.interface.job_notify(Roby::Interface::JOB_READY, 1, 'name')
                            process_call { client.poll }
                        end
                        it "calls the hook only once on jobs created by the interface" do
                            flexmock(client.client).should_receive(:find_action_by_name).once.and_return(true)
                            flexmock(server.interface).should_receive(:start_job).once.and_return(1)
                            process_call { client.client.action! }
                            server.interface.job_notify(Roby::Interface::JOB_READY, 1, 'name')
                            process_call { client.poll }
                        end
                    end
                end
            end
        end
    end
end

