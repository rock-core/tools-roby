# frozen_string_literal: true

require "roby/test/self"
require "roby/interface/v2"
require "roby/tasks/simple"

module Roby
    module Interface
        module V2
            class InterfaceClientTestInterface < Actions::Interface
            end

            describe Client do
                attr_reader :plan
                attr_reader :app
                attr_reader :interface
                attr_reader :server

                def stub_action(name)
                    action = Actions::Models::Action.new("test stub action")
                    InterfaceClientTestInterface.register_action(name, action)
                end

                def stub_command(name)
                    Command.new(name.to_sym, "doc")
                end

                before do
                    @app = Roby::Application.new
                    @plan = app.plan
                    register_plan(plan)

                    interface_class = Class.new(Interface)
                    subsublib = Class.new(CommandLibrary) do
                        def subcommand_test_call(val); end
                    end
                    sublib = Class.new(CommandLibrary) do
                        def subcommand_test_call(val); end
                    end
                    interface_class.subcommand "sublib", sublib, "test subcommand"
                    sublib.subcommand "subsublib", subsublib, "test subcommand"

                    flexmock(@interface = interface_class.new(app))
                    server_socket, @client_socket = Socket.pair(:UNIX, :DGRAM, 0)
                    @server_channel = Channel.new(server_socket, false)
                    @server = Server.new(@server_channel, interface)
                end

                def open_client
                    @client = while_polling_server do
                        Client.new(Channel.new(@client_socket, true), "test")
                    end
                end

                def connect
                    client = open_client
                    while_polling_server do
                        yield(client)
                    end
                ensure
                    client&.close
                end

                def while_polling_server
                    raise "recursive call to #while_polling_server" if @poller

                    @server_channel.reset_thread_guard
                    quit = Concurrent::Event.new
                    @poller = Thread.new do
                        execution_engine.thread = Thread.current
                        until quit.set?
                            @server.poll
                            sleep 0.01
                        end
                    end
                    yield
                ensure
                    quit.set
                    @poller.join
                    @poller = nil
                    execution_engine.thread = Thread.current
                    @server_channel.reset_thread_guard
                end

                after do
                    plan.execution_engine.display_exceptions = true
                    InterfaceClientTestInterface.clear_model
                    @client.close if @client && !@client.closed?
                    server.close unless server.closed?
                end

                it "discovers actions and commands on connection" do
                    interface.should_receive(actions: [stub_action("Test")])
                    commands = CommandLibrary::InterfaceCommands.new(
                        "", nil, Hash[test: stub_command(:test)]
                    )
                    interface.should_receive(commands: Hash["" => commands])

                    commands, actions = connect do |client|
                        [client.commands, client.actions]
                    end
                    assert_equal [:test], commands[""].commands.values.map(&:name)
                    assert(actions.all? { _1.kind_of?(Protocol::ActionModel) })
                    assert_equal ["Test"], actions.map(&:name)
                    assert_equal ["test stub action"], actions.map(&:doc)
                end

                it "dispatches an action call as a start_job message" do
                    interface.should_receive(actions: [stub_action("Test")])
                    interface
                        .should_receive(:start_job)
                        .with("Test", { arg0: 10 }).once
                        .and_return(10)
                    result = connect { |client| client.Test!(arg0: 10) }
                    assert_equal 10, result
                end

                describe "job handling" do
                    before do
                        action_m = Actions::Interface.new_submodel do
                            describe "test"
                            def test
                                Roby::Task.new_submodel
                            end

                            describe "other_test"
                            def other_test
                                Roby::Task.new_submodel
                            end
                        end
                        app.planners << action_m
                    end

                    describe "#each_job" do
                        attr_reader :client, :first_job, :second_job

                        before do
                            @client = open_client
                            while_polling_server do
                                @first_job = client.test!
                                @second_job = client.other_test!
                            end
                        end

                        it "enumerates the jobs" do
                            jobs = while_polling_server { client.each_job.to_a }
                            assert_equal 2, jobs.size
                            assert_equal first_job, jobs[0].job_id
                            assert_equal "test", jobs[0].action_model.name
                            assert_equal second_job, jobs[1].job_id
                            assert_equal "other_test", jobs[1].action_model.name
                        end

                        it "allows to filter them by action name" do
                            jobs = while_polling_server do
                                client.find_all_jobs_by_action_name("test")
                            end
                            assert_equal 1, jobs.size
                            job = jobs.first
                            assert_equal first_job, job.job_id
                            assert_equal "test", job.action_model.name
                        end
                    end

                    it "gets notified of the new jobs on creation" do
                        client = open_client
                        job_id = while_polling_server { client.test! }
                        interface.push_pending_notifications
                        server.poll
                        client.poll
                        assert client.has_job_progress?
                        assert_equal [:monitored, job_id],
                                     client.pop_job_progress[1][0, 2]
                        assert_equal [:planning_ready, job_id],
                                     client.pop_job_progress[1][0, 2]
                    end
                end

                it "raises NoSuchAction on invalid actions "\
                   "without accessing the network" do
                    client = open_client
                    flexmock(client.io).should_receive(:write_packet).never
                    assert_raises(Client::NoSuchAction) do
                        while_polling_server { client.start_job(:Bla, arg0: 10) }
                    end
                    assert_raises(Client::NoSuchAction) do
                        while_polling_server { client.Bla!(arg0: 10) }
                    end
                end

                it "raises NoMethodError on an unknown call" do
                    e = assert_raises(Client::RemoteError) do
                        connect { |client| client.does_not_exist(arg0: 10) }
                    end
                    assert(/does_not_exist/ === e.message)
                end

                it "appends the local client's backtrace to the remote's" do
                    e = assert_raises(Client::RemoteError) do
                        connect { |client| client.does_not_exist(arg0: 10) }
                    end

                    remote_error_line =
                        e.backtrace
                         .index { |l| l =~ %r{interface/v2/server.rb.*process_call} }
                    local_error_line =
                        e.backtrace
                         .index { |l| l =~ /#{__FILE__}:#{__LINE__ - 8}/ }
                    assert(remote_error_line)
                    assert(local_error_line)
                    assert(remote_error_line < local_error_line)
                end

                describe "#find_action_by_name" do
                    it "returns a matching action" do
                        interface.should_receive(actions: [stub_action("Test")])
                        result = connect { |client| client.find_action_by_name("Test") }
                        assert_kind_of Protocol::ActionModel, result
                        assert_equal "Test", result.name
                    end
                    it "returns nil for an unknown action" do
                        refute(connect { |client| client.find_action_by_name("bla") })
                    end
                end

                describe "#find_all_actions_matching" do
                    it "returns a matching action" do
                        interface.should_receive(actions: [stub_action("Test")])
                        result =
                            connect { |client| client.find_all_actions_matching(/Te/) }

                        assert_equal 1, result.size
                        assert_kind_of Protocol::ActionModel, result.first
                        assert_equal "Test", result.first.name
                    end
                    it "returns an empty array for an unknown action" do
                        result =
                            connect { |client| client.find_all_actions_matching(/bla/) }
                        assert_equal [], result
                    end
                end

                describe "command batches" do
                    describe "nominal cases" do
                        before do
                            interface.should_receive(actions: [stub_action("Test")])
                            interface.should_receive(:start_job)
                                     .with("Test", arg: 10).and_return(1).ordered.once
                            interface.should_receive(:kill_job)
                                     .with(1).and_return(2).ordered.once
                            interface.should_receive(:start_job)
                                     .with("Test", arg: 20).and_return(3).ordered.once
                        end

                        it "gathers commands and executes them all at once" do
                            client = open_client
                            batch = client.create_batch
                            batch.Test!(arg: 10)
                            batch.kill_job 1
                            batch.Test!(arg: 20)
                            while_polling_server { client.process_batch(batch) }
                        end

                        it "returns a Return object which contains "\
                           "the calls associated with their return values" do
                            client = open_client
                            batch = client.create_batch
                            batch.Test!(arg: 10)
                            batch.kill_job 1
                            batch.Test!(arg: 20)
                            ret = while_polling_server { client.process_batch(batch) }
                            assert_kind_of Client::BatchContext::Return, ret
                            expected =
                                [[[[], :start_job, ["Test"], { arg: 10 }], 1],
                                 [[[], :kill_job, [1], {}], 2],
                                 [[[], :start_job, ["Test"], { arg: 20 }], 3]]
                                .map do |call, call_ret|
                                    Client::BatchContext::Return::Element
                                        .new(call, call_ret)
                                end
                            assert_equal expected, ret.each_element.to_a
                        end

                        it "the Return object behaves as an enumeration "\
                           "on the return values" do
                            client = open_client
                            batch = client.create_batch
                            batch.Test!(arg: 10)
                            batch.kill_job 1
                            batch.Test!(arg: 20)
                            ret = while_polling_server { client.process_batch(batch) }
                            assert_equal [1, 2, 3], ret.to_a
                            assert_equal [1, 2, 3], ret.each.to_a
                            assert_equal 2, ret[1]
                        end

                        it "the Return may filter on the call name" do
                            client = open_client
                            batch = client.create_batch
                            batch.Test!(arg: 10)
                            batch.kill_job 1
                            batch.Test!(arg: 20)
                            ret = while_polling_server { client.process_batch(batch) }
                            expected =
                                [[[[], :start_job, ["Test"], Hash[arg: 10]], 1],
                                 [[[], :start_job, ["Test"], Hash[arg: 20]], 3]]
                                .map do |call, call_ret|
                                    Client::BatchContext::Return::Element
                                        .new(call, call_ret)
                                end
                            assert_equal expected,
                                         ret.filter(call: :start_job).each_element.to_a
                        end

                        it "the Return provides a shortcut "\
                           "to return the started job IDs" do
                            client = open_client
                            batch = client.create_batch
                            batch.Test!(arg: 10)
                            batch.kill_job 1
                            batch.Test!(arg: 20)
                            ret = while_polling_server { client.process_batch(batch) }
                            assert_equal [1, 3], ret.started_jobs_id
                        end

                        it "the Return provides a shortcut "\
                           "to return the killed job IDs" do
                            client = open_client
                            batch = client.create_batch
                            batch.Test!(arg: 10)
                            batch.kill_job 1
                            batch.Test!(arg: 20)
                            ret = while_polling_server { client.process_batch(batch) }
                            assert_equal [1], ret.killed_jobs_id
                        end

                        it "the Return provides a shortcut "\
                           "to return the dropped job IDs" do
                            interface.should_receive(:drop_job)
                                     .with(2).and_return(4).ordered.once
                            client = open_client
                            batch = client.create_batch
                            batch.Test!(arg: 10)
                            batch.kill_job 1
                            batch.Test!(arg: 20)
                            batch.drop_job 2
                            ret = while_polling_server { client.process_batch(batch) }
                            assert_equal [2], ret.dropped_jobs_id
                        end
                    end

                    it "raises NoSuchAction if trying to queue an unknown action" do
                        client = open_client
                        batch = client.create_batch
                        assert_raises(Client::NoSuchAction) { batch.does_not_exist! }
                    end

                    it "raises NoMethodError if trying to queue "\
                       "a command that is not kill_job" do
                        client = open_client
                        batch = client.create_batch
                        assert_raises(NoMethodError) { batch.actions }
                    end
                end

                it "queues app notifications and allows to retrieve "\
                   "the notifications in FIFO order" do
                    client = open_client
                    app.notify("WARN", "obj", "message 0")
                    app.notify("FATAL", "obj", "message 1")
                    server.poll
                    client.poll
                    assert client.has_notifications?
                    assert_equal ["WARN", "obj", "message 0"],
                                 client.pop_notification.last
                    assert_equal ["FATAL", "obj", "message 1"],
                                 client.pop_notification.last
                    assert !client.has_notifications?
                end

                it "queues ui events and allows to retrieve "\
                   "the notifications in FIFO order" do
                    client = open_client
                    app.ui_event("test-event", 42)
                    app.ui_event("test-event", 84)
                    server.poll
                    client.poll
                    assert client.has_ui_event?
                    assert_equal ["test-event", 42], client.pop_ui_event.last
                    assert_equal ["test-event", 84], client.pop_ui_event.last
                    assert !client.has_ui_event?
                end

                it "queues exceptions and allows to "\
                   "retrieve the notifications in FIFO order" do
                    client = open_client
                    plan.execution_engine.display_exceptions = false
                    plan.add(t0 = Tasks::Simple.new(id: 1))
                    plan.add(t1 = Tasks::Simple.new(id: 2))
                    plan.execution_engine.notify_exception :fatal, Exception.new, [t0]
                    plan.execution_engine.notify_exception :warn, Exception.new, [t1]
                    interface.push_pending_notifications
                    server.poll
                    client.poll
                    assert client.has_exceptions?

                    level, _, tasks, jobs = client.pop_exception.last
                    task_id = tasks.first.arguments[:id]
                    assert_equal [:fatal, [1], Set.new], [level, [task_id], jobs]
                    level, _, tasks, jobs = client.pop_exception.last
                    task_id = tasks.first.arguments[:id]
                    assert_equal [:warn, [2], Set.new], [level, [task_id], jobs]
                    assert !client.has_exceptions?
                end

                it "computes and queues the IDs of the jobs that are involved "\
                   "in the exception" do
                    client = open_client
                    plan.execution_engine.display_exceptions = false
                    task = Class.new(Tasks::Simple) do
                        provides Job
                    end.new(job_id: 1)
                    plan.execution_engine.notify_exception :fatal, Exception.new, [task]
                    interface.push_pending_notifications
                    server.poll
                    client.poll
                    *_, jobs = client.pop_exception.last
                    assert_equal [1], jobs.to_a
                end

                describe "#poll" do
                    attr_reader :client

                    before do
                        @client = open_client
                    end
                    describe "the cycle_end returned value" do
                        it "is false if there was nothing to process" do
                            assert_equal false, client.poll.last
                        end
                        it "is false if it did some processing but no cycle_end "\
                           "has been received" do
                            app.notify "1", "2", "3"
                            assert_equal false, client.poll.last
                        end
                        it "is true if a cycle_end message is received first, "\
                           "and does not do any more message processing" do
                            interface.notify_cycle_end
                            server.poll
                            assert_equal true, client.poll.last
                            assert !client.has_notifications?
                        end

                        it "stops processing at the cycle_end message" do
                            app.notify "1", "2", "3"
                            app.plan.execution_engine.cycle_end({})
                            app.notify "1", "2", "3"
                            assert_equal true, client.poll.last
                            client.pop_notification
                            assert !client.has_notifications?
                        end

                        it "updates cycle_time and cycle_index with "\
                           "the state from the execution engine" do
                            flexmock(plan.execution_engine)
                                .should_receive(:cycle_start)
                                .and_return(start_time = Time.now)
                            flexmock(plan.execution_engine)
                                .should_receive(:cycle_index)
                                .and_return(index = 42)
                            plan.execution_engine.cycle_end({})
                            client.poll
                            assert_equal index, client.cycle_index
                            assert_equal start_time, client.cycle_start_time
                        end
                    end

                    it "raises ProtocolError "\
                       "if getting more than one reply call in one time" do
                        server.io.write_packet [:reply, 0]
                        server.io.write_packet [:reply, 1]
                        assert_raises(ProtocolError) { client.poll }
                    end

                    it "raises ProtocolError if it gets an unknown message" do
                        server.io.write_packet [:unknown]
                        assert_raises(ProtocolError) { client.poll }
                    end

                    it "allows applying a timeout" do
                        server.io.write_packet [:unknown]
                        assert_raises(ProtocolError) { client.poll }
                    end
                end

                describe "subcommands" do
                    it "returns a SubcommandClient object for a known subcommand" do
                        subcommand = connect(&:sublib)
                        assert_kind_of SubcommandClient, subcommand
                        assert_equal "sublib", subcommand.name
                    end
                    it "the returned object allows to call the subcommand's command" do
                        flexmock(@interface.sublib)
                            .should_receive(:subcommand_test_call).explicitly
                            .with(42).and_return(20)
                        result = connect do |client|
                            client.sublib.subcommand_test_call(42)
                        end
                        assert_equal 20, result
                    end
                    it "returns subcommands recursively" do
                        flexmock(@interface.sublib.subsublib)
                            .should_receive(:subcommand_test_call).explicitly
                            .with(42).and_return(20)
                        result = connect do |client|
                            client.sublib.subsublib.subcommand_test_call(42)
                        end
                        assert_equal 20, result
                    end
                end

                describe "#call" do
                    it "returns the remote method call value" do
                        client = open_client
                        @interface.should_receive(:foobar).explicitly.and_return(42)
                        result = while_polling_server do
                            client.call([], :foobar)
                        end
                        assert_equal 42, result
                    end

                    it "times out with the configured call timeout" do
                        client = open_client
                        client.call_timeout = 0.01
                        e = assert_raises(Client::TimeoutError) do
                            client.call([], :foobar)
                        end
                        assert_equal "failed to receive expected reply within 0.01s",
                                     e.message
                    end
                end

                describe "#async_call" do
                    attr_reader :watch
                    attr_reader :async_calls_count

                    before do
                        @watch = flexmock("watch")
                        @async_calls_count = 0
                    end

                    def async_call_and_expect_ordered( # rubocop:disable Metrics/AbcSize,Metrics/ParameterLists
                        client, exp_error, exp_result, seq, path, method_name, *args, **keywords
                    )
                        client.async_call(path, method_name, *args, **keywords) do |error, result|
                            if !exp_error.nil?
                                assert_kind_of Protocol::Error, error
                                assert_equal "#{exp_error.message} (#{exp_error.class})",
                                             error.message.chomp
                            else
                                assert_nil error
                            end
                            assert_equal [exp_result], [result]
                            watch.ping(seq)
                            @async_calls_count += 1
                        end
                        watch.should_receive(:ping).with(seq).once.ordered
                    end

                    it "dispatches an action call and yields the job id" do
                        interface.should_receive(actions: [stub_action("Test")])
                        interface.should_receive(:start_job).with("Test", arg0: 10).once
                                 .and_return(15)

                        connect do |client|
                            async_call_and_expect_ordered(
                                client, nil, 15, 0, [], "Test!", arg0: 10
                            )
                            loop do
                                client.poll
                                break if async_calls_count == 1
                            end
                        end
                    end

                    it "raises RuntimeError if no callback block is given" do
                        client = open_client
                        assert_raises(RuntimeError) do
                            client.async_call([], "Test!", arg0: 10)
                        end
                    end

                    it "raises NoSuchAction on invalid actions "\
                       "without accessing the network" do
                        client = open_client
                        flexmock(client.io).should_receive(:write_packet).never
                        assert_raises(Client::NoSuchAction) do
                            client.async_call([], "Test!", arg0: 10) {}
                        end
                    end

                    it "dispatches a method call and yields the result" do
                        client = open_client
                        async_call_and_expect_ordered(
                            client, nil, "foo", 0, [], "test", 0, 1
                        )
                        server.io.write_packet [:reply, "foo"]
                        client.poll
                    end

                    it "dispatches a method call and yields an exception on error" do
                        client = open_client
                        e = RuntimeError.new("test")
                        async_call_and_expect_ordered(client, e, nil, 0, [], "test", 0, 1)
                        server.io.write_packet [:bad_call, e]
                        client.poll
                    end

                    it "processes async calls and its responses as a FIFO" do
                        client = open_client
                        e = RuntimeError.new("test")
                        async_call_and_expect_ordered(
                            client, nil, "foo", 0, [], "test", 0, 1
                        )
                        async_call_and_expect_ordered(
                            client, e, nil, 1, [], "method", 1, 2
                        )
                        server.io.write_packet [:reply, "foo"]
                        server.io.write_packet [:bad_call, e]
                        server.io.write_packet [:reply, [10, "test"]]
                        assert_equal client.call([], "foo"), [10, "test"]
                    end

                    it "returns true if the async call is still pending" do
                        client = open_client
                        callback = proc {}

                        first_call =
                            client.async_call([], "some_method", "foo", &callback)
                        second_call =
                            client.async_call([], "some_method", "foo", &callback)

                        assert_equal client.async_call_pending?(first_call), true
                        assert_equal client.async_call_pending?(second_call), true
                        server.io.write_packet [:reply, "bar"]
                        client.poll
                        assert_equal client.async_call_pending?(first_call), false
                        assert_equal client.async_call_pending?(second_call), true
                        server.io.write_packet [:reply, "bar"]
                        client.poll
                        assert_equal client.async_call_pending?(first_call), false
                        assert_equal client.async_call_pending?(second_call), false
                    end

                    it "is called when prefixing a method name with async_" do
                        client = open_client
                        callback = proc {}
                        flexmock(client).should_receive(:async_call)
                                        .with([], :test, "some", "foo", callback)
                                        .once.and_return(ret = flexmock)
                        assert_equal ret, client.async_test("some", "foo", &callback)
                    end

                    it "is called with the proper path when prefixing a method name "\
                       "with async_ on a subcommand" do
                        client = open_client
                        subcommand = SubcommandClient.new(client, "sub", "", {})
                        callback = proc {}
                        flexmock(client).should_receive(:async_call)
                                        .with(["sub"], :test, "some", "foo", callback)
                                        .once.and_return(ret = flexmock)
                        assert_equal ret, subcommand.async_test("some", "foo", &callback)
                    end
                end
            end
        end
    end
end
