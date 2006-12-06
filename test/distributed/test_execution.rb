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
		define_method(:start_task) { task.start! }
	    end
	end
	r_task = remote_task(:id => 1)
	p_task = remote_peer.proxy(r_task)

	FlexMock.use do |mock|
	    ev = EventGenerator.new do |event|
		mock.called(event)
	    end

	    mock.should_receive(:called).once
	    p_task.event(:start).on ev
	    remote.start_task
	    apply_remote_command
	end
    end
end

