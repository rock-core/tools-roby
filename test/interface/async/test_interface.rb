# frozen_string_literal: true

require "roby/test/self"
require "roby/interface/async"
require "roby/interface/tcp"
require_relative "client_server_test_helpers"

module Roby
    module Interface
        module Async
            describe Interface do
                include ClientServerTestHelpers

                it "exposes the host" do
                    interface = Interface.new("localhost", port: 20) {}
                    assert_equal "localhost", interface.remote_name
                end

                it "exposes the port" do
                    interface = Interface.new("localhost", port: 20) {}
                    assert_equal 20, interface.remote_port
                end

                describe "connection handling" do
                    it "#poll retries connecting if the connection method raised ConnectionError" do
                        interface = Interface.new { raise ConnectionError }
                        interface.connection_future.wait
                        flexmock(interface, :strict).should_receive(:attempt_connection).once
                        interface.poll
                    end
                    it "#poll retries connecting if the connection method raised ComError" do
                        interface = Interface.new { raise ComError }
                        interface.connection_future.wait
                        flexmock(interface, :strict).should_receive(:attempt_connection).once
                        interface.poll
                    end
                    it "#poll forwards any exception that is not ComError or ConnectionError" do
                        interface = Interface.new { raise ArgumentError }
                        interface.connection_future.wait
                        flexmock(interface, :strict).should_receive(:attempt_connection).never
                        assert_raises(ArgumentError) { interface.poll }
                    end
                end

                describe "#wait" do
                    describe "while connecting" do
                        it "waits for the pending connection attempt to finish and returns true" do
                            interface = Interface.new {}
                            assert interface.wait
                            assert interface.connection_future.complete?
                        end
                        it "with a timeout, the method returns false if the attempt is not finished" do
                            sync = Concurrent::Event.new
                            interface = Interface.new { sync.wait }
                            refute interface.wait(timeout: 0.1)
                            sync.set
                        end
                        it "with a timeout, the method returns true if the attempt is finished" do
                            interface = Interface.new {}
                            assert interface.wait(timeout: 10)
                        end
                    end
                    describe "when connected" do
                        attr_reader :server, :interface

                        before do
                            @server = create_server
                            @interface = connect(server)
                        end
                        it "does not consume the received data" do
                            server.interface.notify_cycle_end
                            assert interface.wait
                            refute interface.client.cycle_index
                            interface.poll
                            assert_equal @app.execution_engine.cycle_index,
                                         interface.client.cycle_index
                        end
                        it "times out if no data is received on the channel" do
                            refute interface.wait(timeout: 0.1)
                        end
                        it "returns true if there is data on the channel without a timeout" do
                            server.interface.notify_cycle_end
                            assert interface.wait
                        end
                        it "returns true if there is data on the channel with a timeout" do
                            server.interface.notify_cycle_end
                            assert interface.wait(timeout: 0.1)
                        end
                        it "returns if the channel is closed" do
                            server.close
                            assert interface.wait
                        end
                        it "blocks if no data is on the channel and no timeout is given" do
                            t = Thread.new { interface.wait }
                            while t.status != "sleep"
                                sleep 0.01
                            end
                            sleep 0.1
                            assert(t.status == "sleep")
                        end
                    end
                end

                describe "reachability hooks" do
                    it "calls on_unreachable once when there are no remote server" do
                        interface = create_client
                        recorder.should_receive(:reachable).never
                        interface.on_reachable { recorder.reachable }
                        recorder.should_receive(:unreachable).once
                        interface.on_unreachable { recorder.unreachable }
                        interface.connection_future.wait
                        interface.poll
                        interface.poll
                    end
                    it "calls on_reachable callback when connected to the remote server" do
                        connect do |interface|
                            recorder.should_receive(:reachable).once.ordered
                            interface.on_reachable { recorder.reachable }
                            recorder.should_receive(:unreachable).never
                            interface.on_unreachable { recorder.unreachable }
                        end
                    end
                    it "passes the current list of jobs as argument to #on_reachable" do
                        server = create_server
                        flexmock(server.interface).should_receive(:jobs)
                                                  .and_return(1 => %w[a b c])
                        recorder
                            .should_receive(:called).once
                            .with(lambda { |jobs|
                                      jobs.size == 1 &&
                                      jobs.first.job_id == 1 &&
                                      jobs.first.state == "a" &&
                                      jobs.first.task == "c"
                                  })
                        connect(server) do |c|
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
                        flexmock(server.interface).should_receive(:jobs).and_return(1 => %w[a b c])
                        jobs = process_call { client.jobs }
                        assert_equal 1, jobs.size
                        job = jobs.first
                        assert_equal 1, job.job_id
                        assert_equal "a", job.state
                        assert_equal "c", job.task
                    end
                end

                describe "job monitors" do
                    before do
                        @job_monitor = flexmock(job_id: 10)
                        @job_monitor.should_receive(:update_state).by_default
                        @job_monitor.should_receive(:finalized?).and_return(false).by_default
                        @interface = connect
                        @client = @interface.client
                        @interface.add_job_monitor(@job_monitor)
                    end

                    it "is active while added" do
                        assert @interface.active_job_monitor?(@job_monitor)
                    end

                    it "is not active when removed" do
                        @interface.remove_job_monitor(@job_monitor)
                        refute @interface.active_job_monitor?(@job_monitor)
                    end

                    it "notifies added job monitors" do
                        @client.queue_job_progress(:new_state, 10, "test")
                        flexmock(@job_monitor).should_receive(:update_state).with(:new_state).once
                        @interface.poll
                    end
                    it "does not notify removed job monitors" do
                        @interface.remove_job_monitor(@job_monitor)
                        @client.queue_job_progress(:new_state, 10, "test")
                        flexmock(@job_monitor).should_receive(:update_state).never
                        @interface.poll
                    end
                    it "auto-deregisters job monitors when the job is finalized" do
                        @client.queue_job_progress(:new_state, 10, "test")
                        flexmock(@job_monitor).should_receive(:finalized?).and_return(true)
                        @interface.poll
                        refute @interface.active_job_monitor?(@job_monitor)
                    end
                    it "accepts an already removed job monitor as argument to #remove_job_monitor" do
                        @interface.remove_job_monitor(@job_monitor)
                        @interface.remove_job_monitor(@job_monitor)
                        refute @interface.active_job_monitor?(@job_monitor)
                    end
                end

                describe "#on_job" do
                    it "calls the hook on the current jobs" do
                        server = create_server
                        client = connect(server)
                        flexmock(server.interface).should_receive(:jobs).and_return(1 => %w[a b c])
                        recorder.should_receive(:job)
                            .once
                            .with(lambda { |job|
                                      job.job_id == 1 &&
                                      job.state == "a" &&
                                      job.task == "c"
                                  })
                        process_call do
                            client.on_job { |j| recorder.job(j) }
                        end
                    end
                    it "calls the hook on the jobs received at connection time" do
                        client = create_client(connect: false)
                        recorder.should_receive(:job)
                            .once
                            .with(lambda { |job|
                                      job.job_id == 1 &&
                                      job.state == "a" &&
                                      job.task == "c"
                                  })
                        client.on_job { |j| recorder.job(j) }

                        server = create_server
                        flexmock(server.interface).should_receive(:jobs).and_return(1 => %w[a b c])

                        future = client.attempt_connection
                        process_call { future.wait }
                    end

                    describe "new jobs" do
                        attr_reader :server, :client, :listener

                        def interface
                            server.interface
                        end

                        before do
                            @server = create_server
                            @client = connect(server)
                            recorder.should_receive(:job)
                                .by_default
                                .once
                                .with(lambda { |job|
                                          job.job_id == 1 &&
                                          job.state == "a" &&
                                          job.task == "c"
                                      })
                            @listener = process_call do
                                client.on_job { |j| recorder.job(j) }
                            end
                            flexmock(server.interface).should_receive(:find_job_info_by_id)
                                .with(1)
                                .and_return(%w[a b c])
                            interface.tracked_jobs << 1
                        end

                        it "calls the hook on jobs created by a third party" do
                            interface.job_notify(Roby::Interface::JOB_READY, 1, "name")
                            interface.push_pending_notifications
                            process_call { client.poll }
                        end
                        it "does not repeatedly call a listener that already ignored a job" do
                            interface.job_notify(Roby::Interface::JOB_READY, 1, "name")
                            interface.push_pending_notifications
                            interface.job_notify(Roby::Interface::JOB_READY, 1, "name")
                            interface.push_pending_notifications
                            flexmock(listener).should_receive(:matches?).once.and_return(false)
                            recorder.should_receive(:job).never
                            process_call { client.poll }
                        end
                        it "does not call the hook on jobs that have already been seen" do
                            interface.job_notify(Roby::Interface::JOB_READY, 1, "name")
                            interface.push_pending_notifications
                            interface.job_notify(Roby::Interface::JOB_READY, 1, "name")
                            interface.push_pending_notifications
                            process_call { client.poll }
                        end
                        it "calls the hook only once on jobs created by the interface" do
                            flexmock(client.client).should_receive(:find_action_by_name).once.and_return(true)
                            flexmock(interface).should_receive(:start_job).once.and_return(1)
                            process_call { client.client.action! }
                            interface.job_notify(Roby::Interface::JOB_READY, 1, "name")
                            interface.push_pending_notifications
                            process_call { client.poll }
                        end
                    end
                end

                describe "job progress" do
                    attr_reader :client, :server

                    before do
                        @server = create_server
                        @client = connect(server)
                    end
                    def interface
                        server.interface
                    end

                    it "updates the state of the monitored jobs" do
                        monitor = flexmock(:on, JobMonitor, job_id: 42, finalized?: false)
                        client.add_job_monitor(monitor)
                        monitor.should_receive(:update_state).with(Roby::Interface::JOB_MONITORED).once.ordered
                        monitor.should_receive(:update_state).with(Roby::Interface::JOB_READY).once.ordered
                        interface.job_notify(Roby::Interface::JOB_MONITORED, 42, "name")
                        interface.job_notify(Roby::Interface::JOB_READY, 42, "name")
                        interface.push_pending_notifications
                        process_call do
                            client.poll
                        end
                    end

                    it "calls #replaced on the job monitor for a REPLACED state change" do
                        monitor = flexmock(:on, JobMonitor, job_id: 42, finalized?: false)
                        client.add_job_monitor(monitor)
                        monitor.should_receive(:update_state).with(Roby::Interface::JOB_MONITORED).once.ordered
                        monitor.should_receive(:update_state).with(Roby::Interface::JOB_REPLACED).once.ordered
                        monitor.should_receive(:replaced).with("new task").once.ordered
                        interface.job_notify(Roby::Interface::JOB_MONITORED, 42, "name")
                        interface.job_notify(Roby::Interface::JOB_REPLACED, 42, "name", "new task")
                        interface.push_pending_notifications
                        process_call do
                            client.poll
                        end
                    end

                    it "calls notify_exception for the exceptions that involve the job" do
                        monitor = flexmock(:on, JobMonitor, job_id: 42, finalized?: false)
                        client.add_job_monitor(monitor)
                        monitor.should_receive(:notify_exception)
                            .with(:fatal, "exception_object").once
                        client.client.queue_exception(:fatal, "exception_object", [], [42])
                        process_call do
                            client.poll
                        end
                    end

                    it "notifies of exceptions for jobs that are finalized in the same cycle" do
                        monitor = JobMonitor.new(client, 42)
                        monitor.start
                        flexmock(monitor).should_receive(:notify_exception)
                            .with(:fatal, "exception_object").once
                        interface.job_notify(Roby::Interface::JOB_MONITORED, 42, "name")
                        client.client.queue_exception(:fatal, "exception_object", [], [42])
                        interface.job_notify(Roby::Interface::JOB_FINALIZED, 42, "name")
                        interface.push_pending_notifications
                        process_call do
                            client.poll
                        end
                    end

                    it "deregisters job handlers once the job is finalized" do
                        monitor = JobMonitor.new(client, 42)
                        monitor.start
                        interface.job_notify(Roby::Interface::JOB_MONITORED, 42, "name")
                        interface.job_notify(Roby::Interface::JOB_FINALIZED, 42, "name")
                        interface.push_pending_notifications
                        process_call do
                            client.poll
                        end
                        refute monitor.active?
                    end
                end

                describe "notifications" do
                    attr_reader :client, :server

                    before do
                        @server = create_server
                        @client = connect(server)
                    end
                    def interface
                        server.interface
                    end

                    it "calls when a new UI event is received" do
                        recorder = flexmock
                        recorder.should_receive(:called).with("test-event", [42]).once
                        app.ui_event "test-event", 42
                        client.on_ui_event do |event_name, *args|
                            recorder.called(event_name, args)
                        end
                        process_call do
                            client.poll
                        end
                    end
                end
            end
        end
    end
end
