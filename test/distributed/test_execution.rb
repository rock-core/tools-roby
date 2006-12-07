$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'distributed/common.rb'
require 'mockups/tasks'
require 'flexmock'

class TC_DistributedExecution < Test::Unit::TestCase
    include DistributedTestCommon

    def setup
	Roby::Distributed.allow_remote_access Roby::Distributed::Peer
	super
    end

    def teardown 
	Distributed.unpublish
	Distributed.state = nil

	super
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

