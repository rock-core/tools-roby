require 'roby/test/distributed'
require 'roby/tasks/simple'

class TC_DistributedExecution < Minitest::Test
    def setup
        super
        Roby.app.filter_backtraces = false
    end

    def test_event_status
	peer2peer do |remote|
	    class << remote
		attr_reader :controlable
		attr_reader :contingent
		def create
		    # Put the task to avoir having GC clearing the events
		    plan.add_mission(t = Tasks::Simple.new(id: 'task'))
		    plan.add(@controlable = Roby::EventGenerator.new(true))
		    plan.add(@contingent = Roby::EventGenerator.new(false))
		    t.signals(:start, controlable, :start)
		    t.forward_to(:start, contingent, :start)
		    nil
		end
		def fire
		    engine.execute do
			controlable.call(nil) 
			contingent.emit(nil)
		    end
		    nil
		end
	    end
	end

	remote.create
	task = subscribe_task(id: 'task')
	controlable = *task.event(:start).child_objects(EventStructure::Signal).to_a
	contingent  = *task.event(:start).child_objects(EventStructure::Forwarding).to_a

	FlexMock.use do |mock|
	    controlable.on do
		mock.fired_controlable(engine.gathering?)
	    end
	    contingent.on do
		mock.fired_contingent(engine.gathering?)
	    end

	    mock.should_receive(:fired_controlable).with(true).once
	    mock.should_receive(:fired_contingent).with(true).once
	    remote.fire
	    remote_peer.synchro_point
	end

	assert(controlable.happened?)
	assert(contingent.happened?)
    end

    def test_signal_establishment
	peer2peer do |remote|
	    Roby::Distributed.on_transaction do |trsc|
		trsc.edit do
		    local_task = trsc.find_tasks.which_fullfills(Roby::Test::Tasks::Simple).to_a.first
		    t = trsc[Tasks::Simple.new(id: 'remote_task')]
		    local_task.depends_on t
		    local_task.signals :start, t, :start
		    nil
		end
	    end
	end

	trsc = Roby::Distributed::Transaction.new(plan)
	trsc.add_owner remote_peer
	trsc.propose(remote_peer)

	plan.add_mission(local_task = Roby::Test::Tasks::Simple.new)
	trsc[local_task]
	trsc.release
	trsc.edit
	trsc.commit_transaction

	engine.execute { local_task.start! }
	engine.wait_one_cycle
	remote_peer.synchro_point
	remote_task = subscribe_task(id: 'remote_task')
	assert(remote_task.running?)

	engine.execute do
	    plan.unmark_mission(local_task)
	    local_task.stop!
	end
    end

    # This test that the event/plan modification order is kept on a remote host
    def test_keeps_causality
	peer2peer do |remote|
	    class << remote
		attr_reader :event
		attr_reader :task
		def create
		    # Put the task to avoir having GC clearing the events
		    plan.add_mission(@task = Tasks::Simple.new(id: 'task'))
		    plan.add(@event = Roby::EventGenerator.new(true))
		    event.signals task.event(:start)
		    nil
		end
		def fire
		    engine.execute do
			event.on do
			    plan.unmark_mission(task)
			    task.event(:start).signals task.event(:success)
			end
		
			event.call(nil) 
		    end
		    nil
		end
	    end
	end

	remote.create
	task = subscribe_task(id: 'task')
	event = *task.event(:start).parent_objects(EventStructure::Signal).to_a

	FlexMock.use do |mock|
	    event.on do
		mock.fired
		assert(plan.free_events.include?(event))
	    end

	    mock.should_receive(:fired).once
	    remote.fire
	    remote_peer.synchro_point
	end

	assert(event.happened?)
    end

    def test_task_status
	Roby.app.abort_on_exception = false
	peer2peer do |remote|
	    class << remote
		include Minitest::Assertions
		attr_reader :task
		def create_task
		    plan.clear
		    plan.add_mission(@task = Tasks::Simple.new(id: 1))
		end
		def start_task; engine.once { task.start! }; nil end
		def stop_task
		    assert(task.executable?)
		    engine.once do
			plan.unmark_mission(task)
			task.stop!
		    end
		    nil
		end
	    end
	end

	remote.create_task
	p_task = remote_task(id: 1)
	assert(!p_task.event(:start).happened?)
	process_events
	assert(!p_task.plan)

	# Start the task *before* subscribing to test that #subscribe maps the
	# task status
	remote.start_task
	process_events
	p_task = subscribe_task(id: 1)
	assert(p_task.running?)
	assert(p_task.event(:start).happened?)

	# Stop the task to see if the fired event is propagated
	remote.stop_task
	process_events
	assert(p_task.finished?)
	assert(p_task.failed?)
	assert(p_task.event(:stop).happened?)
	assert(p_task.finished?)
    end

    def test_signalling
	peer2peer do |remote|
	    remote.plan.add_mission(task = Tasks::Simple.new(id: 1))
	    remote.class.class_eval do
		include Minitest::Assertions
		define_method(:start_task) do
		    events = plan.free_events.to_a
		    assert_equal(2, events.size)
		    assert(sev = events.find { |ev| ev.controlable? })
		    assert(fev = events.find { |ev| !ev.controlable? })
		    assert(task.event(:start).child_object?(sev, Roby::EventStructure::Signal))
		    assert(task.event(:start).child_object?(fev, Roby::EventStructure::Forwarding))
		    engine.once { task.start! }
		    nil
		end
	    end
	end
	p_task = subscribe_task(id: 1)

	FlexMock.use do |mock|
	    signalled_ev = EventGenerator.new do |context|
		mock.signal_command
		signalled_ev.emit(nil)
	    end
	    signalled_ev.on { |ev| mock.signal_emitted }
	    assert(signalled_ev.controlable?)

	    forwarded_ev = EventGenerator.new	
	    forwarded_ev.on { |ev| mock.forward_emitted }
	    assert(!forwarded_ev.controlable?)

	    p_task.event(:start).signals signalled_ev
	    p_task.event(:start).forward_to forwarded_ev

	    mock.should_receive(:signal_command).once.ordered('signal')
	    mock.should_receive(:signal_emitted).once.ordered('signal')
	    mock.should_receive(:forward_emitted).once
	    process_events

	    remote.start_task
	    process_events
	    assert(signalled_ev.happened?)
	    assert(forwarded_ev.happened?)
	end
    end

    def test_event_handlers
	peer2peer do |remote|
	    remote.plan.add_mission(task = Tasks::Simple.new(id: 1))
	    def remote.start(task)
		task = local_peer.local_object(task)
		engine.once { task.start! }
		nil
	    end
	end
	FlexMock.use do |mock|
	    mock.should_receive(:started).once

	    task = subscribe_task(id: 1)
	    task.on(:start) { mock.started }
	    remote.start(Distributed.format(task))
	    process_events

	    assert(task.running?)
	end
    end

    # Test that we can 'forget' running tasks that was known to us because they
    # were related to subscribed tasks
    def test_forgetting
	peer2peer do |remote|
	    parent, child =
		Tasks::Simple.new(id: 'parent'), 
		Tasks::Simple.new(id: 'child')
	    parent.depends_on child

	    remote.plan.add_mission(parent)
	    child.start!
	    remote.singleton_class.class_eval do
		define_method(:remove_link) do
		    parent.remove_child(child)
		end
	    end
	end

	parent   = subscribe_task(id: 'parent')
	child    = nil
	assert(child = local.plan.known_tasks.find { |t| t.arguments[:id] == 'child' })
	assert(!child.subscribed?)
	assert(child.running?)
	remote.remove_link
	process_events
	assert(!local.plan.known_tasks.find { |t| t.arguments[:id] == 'child' })
    end

    # Tests that running remote tasks are aborted and pending tasks GCed if the
    # connection is killed
    def test_disconnect_kills_tasks
	peer2peer do |remote|
	    remote.plan.add_mission(task = Tasks::Simple.new(id: 'remote-1'))
	    def remote.start(task)
		task = local_peer.local_object(task)
		engine.execute do
		    task.start!
		end
		nil
	    end
	end

	task = subscribe_task(id: 'remote-1')
	remote.start(Distributed.format(task))
	process_events
	assert(task.running?)
	assert(task.child_object?(remote_peer.task, TaskStructure::ExecutionAgent))
	assert(task.subscribed?)

	engine.execute do
	    remote_peer.disconnected!
	end
	assert(!task.subscribed?)
	assert(remote_peer.task.finished?)
	assert(remote_peer.task.event(:aborted).happened?)
	assert(remote_peer.task.event(:stop).happened?)
	assert(task.finished?)
    end

    # Checks that the code blocks are called only in owning controllers
    class CodeBlocksOwnersMockup < Roby::Test::Tasks::Simple
	attr_reader :command_called
	event :start do |context|
	    @command_called = true
	    emit :start
	end

	attr_reader :handler_called
	on(:start) { |event| @handler_called = true }

	attr_reader :poller_called
	poll { @poller_called = true }
    end

    def test_code_blocks_owners
	peer2peer do |remote|
	    remote.plan.add_mission(CodeBlocksOwnersMockup.new(id: 'mockup'))

	    def remote.call
		task = plan.find_tasks(CodeBlocksOwnersMockup).to_a.first
		engine.execute { task.start! }
	    end

	    def remote.blocks_called
		task = plan.find_tasks(CodeBlocksOwnersMockup).to_a.first
		task.command_called && task.poller_called && task.handler_called
	    end
	end

	mockup = subscribe_task(id: 'mockup')
	remote.call
	remote_peer.synchro_point

	assert(remote.blocks_called)
	assert(!mockup.command_called)
	assert(!mockup.poller_called)
	assert(!mockup.handler_called)
    end

    # Checks that we get the update fine if +fired+ and +signalled+ are
    # received in the same cycle
    def test_joint_fired_signalled
	peer2peer do |remote|
	    remote.plan.add_mission(task = Tasks::Simple.new(id: 'remote-1'))
	    engine.once { task.start! }
	end
	    
	event_time = Time.now
	remote = subscribe_task(id: 'remote-1')
	plan.add_mission(local = Tasks::Simple.new(id: 'local'))
	remote_peer.synchro_point

	engine.execute do
	    remote_peer.local_server.event_fired(remote.event(:success), 0, Time.now, [42])
	    remote_peer.local_server.event_add_propagation(true, remote.event(:success), local.event(:start), 0, event_time, [42])
	end
	process_events

	assert(remote.finished?)
	assert(remote.success?)
	assert(local.started?)
	assert_equal(1, remote.history.size, remote.history)
    end
end

