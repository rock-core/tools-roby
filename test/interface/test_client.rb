require 'roby/test/self'
require 'roby/interface'
require 'roby/tasks/simple'

module Roby
    module Interface
        class InterfaceClientTestInterface < Actions::Interface
        end

        describe Client do
            attr_reader :plan
            attr_reader :app
            attr_reader :interface
            attr_reader :client
            attr_reader :server

            def stub_action(name)
                action = Actions::Models::Action.new(InterfaceClientTestInterface)
                InterfaceClientTestInterface.register_action(name, action)
                action
            end

            def stub_command(name)
                Command.new(name.to_sym, 'doc')
            end

            let :interface_mock do
                flexmock(Interface.new(app))
            end

            before do
                @app = Roby::Application.new
                @plan = app.plan
                register_plan(plan)

                @interface = interface_mock
                server_socket, @client_socket = Socket.pair(:UNIX, :DGRAM, 0) 
                @server    = Server.new(DRobyChannel.new(server_socket, false), interface)
                @server_thread = Thread.new do
                    plan.execution_engine.thread = Thread.current
                    begin
                        while true
                            server.poll
                            sleep 0.01
                        end
                    rescue ComError
                    end
                end
                @server_thread.abort_on_exception = true
            end

            let :client do
                Client.new(DRobyChannel.new(@client_socket, true), 'test')
            end

            after do
                plan.execution_engine.display_exceptions = true
                InterfaceClientTestInterface.clear_model
                client.close if !client.closed?
                server.close if !server.closed?
                begin @server_thread.join
                rescue Interrupt
                end
            end

            it "discovers actions and commands on connection" do
                interface_mock.should_receive(actions:  [stub_action("Test")])
                commands = CommandLibrary::InterfaceCommands.new('', nil, Hash[test: stub_command(:test)])
                interface_mock.should_receive(commands: Hash['' => commands])
                assert_equal [:test], client.commands[''].commands.values.map(&:name)
                assert_equal interface_mock.actions, client.actions
            end

            it "dispatches an action call as a start_job message" do
                interface_mock.should_receive(actions:  [stub_action("Test")])
                interface_mock.should_receive(:start_job).with('Test', arg0: 10).once.
                    and_return(10)
                assert_equal 10, client.Test!(arg0: 10)
            end

            describe "job handling" do
                before do
                    action_m = Actions::Interface.new_submodel do
                        describe 'test'
                        def test; Roby::Task.new_submodel end
                        describe 'other_test'
                        def other_test; Roby::Task.new_submodel end
                    end
                    app.planners << action_m
                end

                describe "#each_job" do
                    attr_reader :test_id, :other_test_id
                    before do
                        @test_id = client.test!
                        @other_test_id = client.other_test!
                    end

                    it "enumerates the jobs" do
                        jobs = client.each_job.to_a
                        assert_equal 2, jobs.size
                        assert_equal test_id, jobs[0].job_id
                        assert_equal 'test', jobs[0].action_model.name
                        assert_equal other_test_id, jobs[1].job_id
                        assert_equal 'other_test', jobs[1].action_model.name
                    end

                    it "allows to filter them by action name" do
                        jobs = client.find_all_jobs_by_action_name('test')
                        assert_equal 1, jobs.size
                        job = jobs.first
                        assert_equal test_id, job.job_id
                        assert_equal 'test', job.action_model.name
                    end
                end

                it "gets notified of the new jobs on creation" do
                    job_id = client.test!
                    interface_mock.push_pending_job_notifications
                    client.poll
                    assert client.has_job_progress?
                    assert_equal [:monitored, job_id], client.pop_job_progress[1][0, 2]
                    assert_equal [:planning_ready, job_id], client.pop_job_progress[1][0, 2]
                end
            end

            it "raises NoSuchAction on invalid actions without accessing the network" do
                flexmock(client.io).should_receive(:write_packet).never
                assert_raises(Client::NoSuchAction) { client.start_job(:Bla, arg0: 10) }
                assert_raises(Client::NoSuchAction) { client.Bla!(arg0: 10) }
            end

            it "raises NoMethodError on an unknown call" do
                e = assert_raises(Exception::DRoby) { client.does_not_exist(arg0: 10) }
                assert_kind_of NoMethodError, e
                assert(/does_not_exist/ === e.message)
            end

            it "appends the local client's backtrace to the remote's" do
                e = assert_raises(Exception::DRoby) { client.does_not_exist(arg0: 10) }
                assert(remote = e.backtrace.index { |l| l =~ /interface\/server.rb.*process_call/ })
                assert(local  = e.backtrace.index { |l| l =~ /#{__FILE__}:#{__LINE__-2}/ })
                assert(remote < local)
            end

            describe "#find_action_by_name" do
                it "returns a matching action" do
                    interface_mock.should_receive(actions:  [stub_action("Test")])
                    assert_equal interface_mock.actions.first, client.find_action_by_name('Test')
                end
                it "returns nil for an unknown action" do
                    assert !client.find_action_by_name('bla')
                end
            end

            describe "#find_all_actions_matching" do
                it "returns a matching action" do
                    interface_mock.should_receive(actions:  [stub_action("Test")])
                    assert_equal [interface_mock.actions.first],
                        client.find_all_actions_matching(/Te/)
                end
                it "returns an empty array for an unknown action" do
                    assert_equal [], client.find_all_actions_matching(/bla/)
                end
            end

            describe "command batches" do
                describe "nominal cases" do
                    before do
                        interface_mock.should_receive(actions:  [stub_action("Test")])
                        interface_mock.should_receive(:start_job).with('Test', arg: 10).and_return(1).ordered.once
                        interface_mock.should_receive(:kill_job).with(1).and_return(2).ordered.once
                        interface_mock.should_receive(:start_job).with('Test', arg: 20).and_return(3).ordered.once
                    end

                    it "gathers commands and executes them all at once" do
                        batch = client.create_batch
                        batch.Test!(arg: 10)
                        batch.kill_job 1
                        batch.Test!(arg: 20)
                        client.process_batch(batch)
                    end

                    it "returns a Return object which contains the calls associated with their return values" do
                        batch = client.create_batch
                        batch.Test!(arg: 10)
                        batch.kill_job 1
                        batch.Test!(arg: 20)
                        ret = client.process_batch(batch)
                        assert_kind_of Client::BatchContext::Return, ret
                        expected = [[[[], :start_job, 'Test', Hash[arg: 10]], 1],
                                    [[[], :kill_job, 1], 2],
                                    [[[], :start_job, 'Test', Hash[arg: 20]], 3]].
                            map do |call, ret|
                                Client::BatchContext::Return::Element.new(call, ret)
                            end
                        assert_equal expected, ret.each_element.to_a
                    end

                    it "the Return object behaves as an enumeration on the return values" do
                        batch = client.create_batch
                        batch.Test!(arg: 10)
                        batch.kill_job 1
                        batch.Test!(arg: 20)
                        ret = client.process_batch(batch)
                        assert_equal [1, 2, 3], ret.to_a
                        assert_equal [1, 2, 3], ret.each.to_a
                        assert_equal 2, ret[1]
                    end

                    it "the Return may filter on the call name" do
                        batch = client.create_batch
                        batch.Test!(arg: 10)
                        batch.kill_job 1
                        batch.Test!(arg: 20)
                        ret = client.process_batch(batch)
                        expected = [[[[], :start_job, 'Test', Hash[arg: 10]], 1],
                                    [[[], :start_job, 'Test', Hash[arg: 20]], 3]].
                            map do |call, ret|
                                Client::BatchContext::Return::Element.new(call, ret)
                            end
                        assert_equal expected, ret.filter(call: :start_job).each_element.to_a
                    end

                    it "the Return provides a shortcut to return the started job IDs" do
                        batch = client.create_batch
                        batch.Test!(arg: 10)
                        batch.kill_job 1
                        batch.Test!(arg: 20)
                        ret = client.process_batch(batch)
                        assert_equal [1, 3], ret.started_jobs_id
                    end

                    it "the Return provides a shortcut to return the killed job IDs" do
                        batch = client.create_batch
                        batch.Test!(arg: 10)
                        batch.kill_job 1
                        batch.Test!(arg: 20)
                        ret = client.process_batch(batch)
                        assert_equal [1], ret.killed_jobs_id
                    end

                    it "the Return provides a shortcut to return the dropped job IDs" do
                        interface_mock.should_receive(:drop_job).with(2).and_return(4).ordered.once
                        batch = client.create_batch
                        batch.Test!(arg: 10)
                        batch.kill_job 1
                        batch.Test!(arg: 20)
                        batch.drop_job 2
                        ret = client.process_batch(batch)
                        assert_equal [2], ret.dropped_jobs_id
                    end
                end

                it "raises NoSuchAction if trying to queue an unknown action" do
                    batch = client.create_batch
                    assert_raises(Client::NoSuchAction) { batch.does_not_exist! }
                end

                it "raises NoMethodError if trying to queue a command that is not kill_job" do
                    batch = client.create_batch
                    assert_raises(NoMethodError) { batch.actions }
                end
            end

            it "queues app notifications and allows to retrieve the notifications in FIFO order" do
                app.notify('WARN', 'obj', 'message 0')
                app.notify('FATAL', 'obj', 'message 1')
                client.poll
                assert client.has_notifications?
                assert_equal ['WARN', 'obj', 'message 0'], client.pop_notification.last
                assert_equal ['FATAL', 'obj', 'message 1'], client.pop_notification.last
                assert !client.has_notifications?
            end

            it "queues exceptions and allows to retrieve the notifications in FIFO order" do
                plan.execution_engine.display_exceptions = false
                plan.add(t0 = Tasks::Simple.new(id: 1))
                plan.add(t1 = Tasks::Simple.new(id: 2))
                plan.execution_engine.notify_exception :fatal, Exception.new, [t0]
                plan.execution_engine.notify_exception :warn, Exception.new, [t1]
                client.poll
                assert client.has_exceptions?

                level, exception, tasks, jobs = client.pop_exception.last
                assert_equal [:fatal, [1], Set.new], [level, tasks.map(&:id), jobs]
                level, exception, tasks, jobs = client.pop_exception.last
                assert_equal [:warn, [2], Set.new], [level, tasks.map(&:id), jobs]
                assert !client.has_exceptions?
            end

            it "computes and queues the IDs of the jobs that are involved in the exception" do
                plan.execution_engine.display_exceptions = false
                task = Class.new(Tasks::Simple) do
                    provides Job
                end.new(job_id: 1)
                plan.execution_engine.notify_exception :fatal, Exception.new, [task]
                client.poll
                *_, jobs = client.pop_exception.last
                assert_equal [1], jobs.to_a
            end

            describe "#poll" do
                describe "the cycle_end returned value" do
                    it "is false if there was nothing to process" do
                        assert_equal false, client.poll.last
                    end
                    it "is false if it did some processing but no cycle_end has been received" do
                        app.notify '1', '2', '3'
                        assert_equal false, client.poll.last
                    end
                    it "is true if a cycle_end message is received first, and does not do any more message processing" do
                        # 'client' is lazily loaded, create it now to avoid
                        # interference
                        client
                        interface_mock.notify_cycle_end
                        assert_equal true, client.poll.last
                        assert !client.has_notifications?
                    end

                    it "stops processing at the cycle_end message" do
                        # 'client' is lazily loaded, create it now to avoid
                        # interference
                        client
                        app.notify '1', '2', '3'
                        app.plan.execution_engine.cycle_end(Hash.new)
                        app.notify '1', '2', '3'
                        assert_equal true, client.poll.last
                        client.pop_notification
                        assert !client.has_notifications?
                    end

                    it "updates cycle_time and cycle_index with the state from the execution engine" do
                        flexmock(plan.execution_engine).should_receive(:cycle_start).and_return(start_time = Time.now)
                        flexmock(plan.execution_engine).should_receive(:cycle_index).and_return(index = 42)
                        plan.execution_engine.cycle_end(Hash.new)
                        client.poll
                        assert_equal index, client.cycle_index
                        assert_equal start_time, client.cycle_start_time
                    end
                end

                it "raises ProtocolError if getting more than one reply call in one time" do
                    server.io.write_packet [:reply, 0]
                    server.io.write_packet [:reply, 1]
                    assert_raises(ProtocolError) { client.poll }
                end

                it "raises ProtocolError if it gets an unknown message" do
                    server.io.write_packet [:unknown]
                    assert_raises(ProtocolError) { client.poll }
                end
            end
        end
    end
end

