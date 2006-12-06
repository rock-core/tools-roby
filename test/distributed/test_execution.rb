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
		    ev = plan.free_events.find { true }
		    assert(ev)
		    assert(ev.controlable?)
		    assert(task.event(:start).child_object?(ev, Roby::EventStructure::Signal))
		    task.start! 
		    assert(task.running?)
		end
	    end
	end
	r_task = remote_task(:id => 1)
	p_task = remote_peer.proxy(r_task)

	FlexMock.use do |mock|
	    ev = EventGenerator.new do |event|
		mock.called(event)
		ev.emit(nil)
	    end
	    assert(ev.controlable?)

	    mock.should_receive(:called).once
	    p_task.event(:start).on ev
	    apply_remote_command
	    remote.start_task

	    apply_remote_command
	    Control.instance.process_events
	    assert(ev.happened?)
	end
    end
end

