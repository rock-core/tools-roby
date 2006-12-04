
module Roby
    module Distributed
	# Set of hooks to send Plan updates to remote hosts
	module PlanModificationHooks
	    def inserted(tasks)
		unless Distributed.updating?([self])
		    Distributed.each_subscribed_peer(self) do |peer|
			peer.plan_update(:insert, self, tasks)
		    end
		end
	    end
	    def discovered(tasks)
		unless Distributed.updating?([self])
		    Distributed.each_subscribed_peer(self) do |peer|
			peer.plan_update(:discover, self, tasks)
		    end
		end
	    end
	    def discarded(tasks)
		unless Distributed.updating?([self])
		    Distributed.each_subscribed_peer(self) do |peer|
			tasks = tasks.find_all { |t| peer.local.subscribed?(t) }
			peer.plan_update(:discard, self, tasks)
		    end
		end
	    end
	    def replaced(from, to)
		Distributed.each_subscribed_peer(from) do |peer|
		    peer.plan_update(:replace, self, from, to)
		end
	    end
	    def finalized_task(task)
		Distributed.each_subscribed_peer(task) do |peer|
		    peer.plan_update(:remove_object, self, task)
		end
	    end
	    def finalized_event(event)
		Distributed.each_subscribed_peer(event) do |peer|
		    peer.plan_update(:remove_object, self, event)
		end
	    end
	    def added_transaction(trsc)
		Distributed.each_subscribed_peer(self) do |peer|
		    peer.transaction_update(:added_transaction, self, trsc)
		end
	    end
	    def removed_transaction(trsc)
		Distributed.each_subscribed_peer(trsc) do |peer|
		    peer.transaction_update(:removed_transaction, self, trsc)
		end
	    end
	end
	Plan.include PlanModificationHooks

	class PeerServer
	    NEW_TASK_EVENTS = [:insert, :discover]
	    def plan_update(event, marshalled_plan, *args)
		plan = peer.proxy(marshalled_plan)

		unmarshall_and_update(args) do |unmarshalled|
		    plan.send(event, *unmarshalled)
		end

		case event
		when :discover
		    args[0].each { |obj| peer.subscribe(obj) }

		when :replace 
		    peer.unsubscribe(args[0])
		    peer.subscribe(args[1])

		when :remove_object
		    peer.unsubscribe(args[0])
		end
	    end

	    def transaction_update(marshalled_plan, event, marshalled_trsc)
		plan = peer.proxy(marshalled_plan)
		if event == :removed_transaction
		    trsc = peer.proxy(marshalled_trsc)
		end
	    end
	end
	class Peer
	    def plan_update(*args); send(:plan_update, *args) end
	    def transaction_update(*args); send(:transaction_update, *args) end
	end

	# Set of hooks to propagate relation modifications for subscribed tasks
	module RelationModificationHooks
	    def added_child_object(child, type, info)
		super if defined? super

		return unless Distributed.state
		return if Distributed.updating?([self.root_object, child.root_object])
		Distributed.each_subscribed_peer(self.root_object, child.root_object) do |peer|
		    peer.send(:update_relation, [self, :add_child_object, child, type, info])
		end
	    end

	    def removed_child_object(child, type)
		super if defined? super

		return unless Distributed.state
		return if Distributed.updating?([self.root_object, child.root_object])
		Distributed.each_subscribed_peer(self.root_object, child.root_object) do |peer|
		    peer.send(:update_relation, [self, :remove_child_object, child, type])
		end
	    end
	end
	Task.include(RelationModificationHooks)
	EventGenerator.include(RelationModificationHooks)
    end
end
