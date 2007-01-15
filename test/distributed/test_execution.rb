$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'distributed/common.rb'
require 'mockups/tasks'
require 'flexmock'

class TC_DistributedExecution < Test::Unit::TestCase
    include DistributedTestCommon

    def test_event_status
	peer2peer do |remote|
	    class << remote
		attr_reader :controlable
		attr_reader :contingent
		def create
		    plan.discover(@controlable = Roby::EventGenerator.new(true))
		    plan.discover(@contingent = Roby::EventGenerator.new(false))
		end
		def fire
		    controlable.call(nil) 
		    contingent.emit(nil)
		end
	    end
	end

	remote.create
	r_controlable = remote.controlable
	r_contingent = remote.contingent
	p_controlable = remote_peer.proxy(r_controlable)
	p_contingent = remote_peer.proxy(r_contingent)

	remote.fire
	remote_peer.subscribe(r_controlable.remote_object)
	remote_peer.subscribe(r_contingent.remote_object)
	apply_remote_command

	assert(p_controlable.happened?)
	assert(p_contingent.happened?)
    end

    def test_task_status
	peer2peer do |remote|
	    class << remote
		attr_reader :task
		def create_task
		    plan.clear
		    plan.insert(@task = SimpleTask.new(:id => 1))
		end
		def start_task; task.start! end
		def stop_task; task.stop! end
	    end
	end

	remote.create_task
	r_task = remote_task(:id => 1)
	p_task = remote_peer.proxy(r_task)
	assert(!p_task.event(:start).happened?)

	# Start the task *before* subscribing to test that
	# #subscribe maps the task status
	remote.start_task
	apply_remote_command
	remote_peer.subscribe(r_task.remote_object)
	apply_remote_command

	assert(p_task.event(:start).happened?)
	assert(p_task.running?)

	# Stop the task to see if the fired event is propagated
	remote.stop_task
	apply_remote_command
	assert(p_task.event(:stop).happened?)
	assert(p_task.finished?)
    end

    def test_signalling
	peer2peer do |remote|
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
		    task.start! 
		    assert(task.running?)
		end
	    end
	end
	r_task = remote_task(:id => 1)
	p_task = remote_peer.proxy(r_task)

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
	    forwarded_ev.emit_on p_task.event(:start)

	    mock.should_receive(:signal_command).once.ordered('signal')
	    mock.should_receive(:signal_emitted).once.ordered('signal')
	    mock.should_receive(:forward_emitted).once
	    apply_remote_command
	    remote.start_task

	    apply_remote_command
	    Control.instance.process_events
	    assert(signalled_ev.happened?)
	    assert(forwarded_ev.happened?)
	end
    end
end

