$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'distributed/common.rb'
require 'mockups/tasks'

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
	    remote.insert(Task.new(:id => 1))
	end
	r_task = remote_task(:id => 1)
	task = Task.new

	# Get a proxy for r_task
	p_task = remote_peer.proxy(r_task)
	# More tricky, get a proxy *on remote* for +task+
    end
end

