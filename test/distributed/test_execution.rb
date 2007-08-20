$LOAD_PATH.unshift File.expand_path('../..', File.dirname(__FILE__))
require 'roby/test/distributed'
require 'roby/test/tasks/simple_task'
require 'flexmock'

class TC_DistributedExecution < Test::Unit::TestCase
    include Roby::Distributed::Test

    def test_event_status
	peer2peer(true) do |remote|
	    class << remote
		attr_reader :controlable
		attr_reader :contingent
		def create
		    # Put the task to avoir having GC clearing the events
		    plan.insert(t = SimpleTask.new(:id => 'task'))
		    plan.discover(@controlable = Roby::EventGenerator.new(true))
		    plan.discover(@contingent = Roby::EventGenerator.new(false))
		    t.on(:start, controlable)
		    t.forward(:start, contingent)
		    nil
		end
		def fire
		    Roby.execute do
			controlable.call(nil) 
			contingent.emit(nil)
		    end
		    nil
		end
	    end
	end

	remote.create
	task = subscribe_task(:id => 'task')
	controlable = *task.event(:start).child_objects(EventStructure::Signal).to_a
	contingent  = *task.event(:start).child_objects(EventStructure::Forwarding).to_a

	FlexMock.use do |mock|
	    controlable.on do
		mock.fired_controlable(Roby::Propagation.gathering?)
	    end
	    contingent.on do
		mock.fired_contingent(Roby::Propagation.gathering?)
	    end

	    mock.should_receive(:fired_controlable).with(true).once
	    mock.should_receive(:fired_contingent).with(true).once
	    remote.fire
	    remote_peer.synchro_point
	end

	assert(controlable.happened?)
	assert(contingent.happened?)
    end

    def test_keeps_causality
	peer2peer(true) do |remote|
	    class << remote
		attr_reader :event
		attr_reader :task
		def create
		    # Put the task to avoir having GC clearing the events
		    plan.insert(@task = SimpleTask.new(:id => 'task'))
		    plan.discover(@event = Roby::EventGenerator.new(true))
		    task.on(:start, event)
		    nil
		end
		def fire
		    Roby.execute do
			event.call(nil) 
			plan.discard(task)
		    end
		    nil
		end
	    end
	end

	remote.create
	task = subscribe_task(:id => 'task')
	event = *task.event(:start).child_objects(EventStructure::Signal).to_a

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
	Roby.control.abort_on_exception = false
	peer2peer(true) do |remote|
	    class << remote
		include Test::Unit::Assertions
		attr_reader :task
		def create_task
		    plan.clear
		    plan.insert(@task = SimpleTask.new(:id => 1))
		end
		def start_task; Roby::Control.once { task.start! }; nil end
		def stop_task
		    assert(task.executable?)
		    Roby::Control.once { task.stop!  }
		    nil
		end
	    end
	end

	remote.create_task
	p_task = remote_task(:id => 1)
	assert(!p_task.event(:start).happened?)
	process_events
	assert(!p_task.plan)

	# Start the task *before* subscribing to test that #subscribe maps the
	# task status
	remote.start_task
	process_events
	p_task = subscribe_task(:id => 1)
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
	peer2peer(true) do |remote|
	    remote.plan.insert(task = SimpleTask.new(:id => 1))
	    remote.class.class_eval do
		include Test::Unit::Assertions
		define_method(:start_task) do
		    events = plan.free_events.to_a
		    assert_equal(2, events.size)
		    assert(sev = events.find { |ev| ev.controlable? })
		    assert(fev = events.find { |ev| !ev.controlable? })
		    assert(task.event(:start).child_object?(sev, Roby::EventStructure::Signal))
		    assert(task.event(:start).child_object?(fev, Roby::EventStructure::Forwarding))
		    Control.once { task.start! }
		    nil
		end
	    end
	end
	p_task = subscribe_task(:id => 1)

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

	    p_task.event(:start).on signalled_ev
	    p_task.event(:start).forward forwarded_ev

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
	peer2peer(true) do |remote|
	    remote.plan.insert(task = SimpleTask.new(:id => 1))
	    def remote.start(task)
		task = local_peer.local_object(task)
		Roby::Control.once { task.start! }
		nil
	    end
	end
	FlexMock.use do |mock|
	    mock.should_receive(:started).once

	    task = subscribe_task(:id => 1)
	    task.on(:start) { mock.started }
	    remote.start(task)
	    process_events

	    assert(task.running?)
	end
    end

    # Test that we can 'forget' running tasks that was known to us because they
    # were related to subscribed tasks
    def test_forgetting
	peer2peer(true) do |remote|
	    parent, child =
		SimpleTask.new(:id => 'parent'), 
		SimpleTask.new(:id => 'child')
	    parent.realized_by child

	    remote.plan.insert(parent)
	    child.start!
	    remote.singleton_class.class_eval do
		define_method(:remove_link) do
		    parent.remove_child(child)
		end
	    end
	end

	parent   = subscribe_task(:id => 'parent')
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
	peer2peer(true) do |remote|
	    remote.plan.insert(task = SimpleTask.new(:id => 'remote-1'))
	    def remote.start(task)
		task = local_peer.local_object(task)
		Roby.execute do
		    task.start!
		end
		nil
	    end
	end

	task = subscribe_task(:id => 'remote-1')
	remote.start(Distributed.format(task))
	process_events
	assert(task.running?)
	assert(task.child_object?(remote_peer.task, TaskStructure::ExecutionAgent))
	assert(task.subscribed?)

	Roby.execute do
	    remote_peer.disconnected!
	end
	assert(!task.subscribed?)
	assert(remote_peer.task.finished?)
	assert(remote_peer.task.event(:aborted).happened?)
	assert(remote_peer.task.event(:stop).happened?)
	assert(task.finished?)
    end

    # Checks that we get the update fine if +fired+ and +signalled+ are
    # received in the same cycle
    def test_joint_fired_signalled
	peer2peer(true) do |remote|
	    remote.plan.insert(task = SimpleTask.new(:id => 'remote-1'))
	    Roby::Control.once { task.start! }
	end
	    
	event_time = Time.now
	remote = subscribe_task(:id => 'remote-1')
	plan.insert(local = SimpleTask.new(:id => 'local'))
	remote_peer.synchro_point

	Roby.execute do
	    remote_peer.local_server.event_fired(remote.event(:success), 0, Time.now, 42)
	    remote_peer.local_server.event_add_propagation(true, remote.event(:success), local.event(:start), 0, event_time, 42)
	end
	process_events

	assert(remote.finished?)
	assert(remote.success?)
	assert(local.started?)
	assert_equal(1, remote.history.size, remote.history)
    end
end

