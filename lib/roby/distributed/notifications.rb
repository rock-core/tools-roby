
module Roby
    module Distributed
	# Set of hooks to send Plan updates to remote hosts
	module PlanModificationHooks
	    def inserted(tasks)
		super if defined? super
		unless Distributed.updating?([self])
		    Distributed.each_subscribed_peer(self) do |peer|
			peer.plan_update(:insert, self, tasks)
		    end
		end
	    end
	    def discovered_tasks(tasks)
		super if defined? super
		unless Distributed.updating?([self])
		    Distributed.each_subscribed_peer(self) do |peer|
			peer.plan_update(:discover, self, tasks)
		    end
		end
	    end
	    alias :discovered_events :discovered_tasks

	    def discarded(tasks)
		super if defined? super
		unless Distributed.updating?([self])
		    Distributed.each_subscribed_peer(self) do |peer|
			tasks = tasks.find_all { |t| peer.local.subscribed?(t) }
			peer.plan_update(:discard, self, tasks)
		    end
		end
	    end
	    def replaced(from, to)
		super if defined? super
		Distributed.each_subscribed_peer(from) do |peer|
		    peer.plan_update(:replace, self, from, to)
		end
	    end
	    def finalized_task(task)
		super if defined? super
		Distributed.each_subscribed_peer(task) do |peer|
		    peer.plan_update(:remove_object, self, task)
		end
	    end
	    def finalized_event(event)
		super if defined? super
		Distributed.each_subscribed_peer(event) do |peer|
		    peer.plan_update(:remove_object, self, event)
		end
	    end
	    def added_transaction(trsc)
		super if defined? super
		Distributed.each_subscribed_peer(self) do |peer|
		    peer.transaction_update(:added_transaction, self, trsc)
		end
	    end
	    def removed_transaction(trsc)
		super if defined? super
		Distributed.each_subscribed_peer(trsc) do |peer|
		    peer.transaction_update(:removed_transaction, self, trsc)
		end
	    end
	end
	Plan.include PlanModificationHooks

	class PeerServer
	    NEW_TASK_EVENTS = [:insert, :discover]
	    def set_plan(marshalled_plan, missions, known_tasks)
		known_tasks.each do |task|
		    peer.subscribe(task)
		end
	    end
	    def plan_update(event, marshalled_plan, *args)
		plan = peer.proxy(marshalled_plan)
		Distributed.update([plan]) do
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
	    end

	    def transaction_update(marshalled_plan, event, marshalled_trsc)
		plan = peer.proxy(marshalled_plan)
		if event == :removed_transaction
		    trsc = peer.proxy(marshalled_trsc)
		end
	    end
	end
	class Peer
	    def plan_update(*args); transmit(:plan_update, *args) end
	    def transaction_update(*args); transmit(:transaction_update, *args) end
	end

	# Set of hooks to propagate relation modifications for subscribed tasks
	module RelationModificationHooks
	    def added_child_object(child, type, info)
		super if defined? super

		return unless Distributed.state
		return if Distributed.updating?([self.root_object, child.root_object])
		Distributed.each_subscribed_peer(self.root_object, child.root_object) do |peer|
		    peer.transmit(:update_relation, [self, :add_child_object, child, type, info])
		end
	    end

	    def removed_child_object(child, type)
		super if defined? super

		return unless Distributed.state
		return if Distributed.updating?([self.root_object, child.root_object])
		Distributed.each_subscribed_peer(self.root_object, child.root_object) do |peer|
		    peer.transmit(:update_relation, [self, :remove_child_object, child, type])
		end
	    end
	end
	PlanObject.include RelationModificationHooks

	module EventNotifications
	    def forwarding(event, to)
		super if defined? super
		if self_owned? && !Distributed.updating?([self])
		    Distributed.each_subscribed_peer(self, to) do |peer|
			peer.transmit(:event_add_propagation, true, self, to, event.time, event.context)
		    end
		end
	    end
	    def signalling(event, to)
		super if defined? super
		if self_owned? && !Distributed.updating?([self])
		    Distributed.each_subscribed_peer(self, to) do |peer|
			peer.transmit(:event_add_propagation, false, self, to, event.time, event.context)
		    end
		end
	    end
	end
	Roby::EventGenerator.include EventNotifications

	class PeerServer
	    def event_add_propagation(only_forward, marshalled_from, marshalled_to, time, context)
		from_generator = peer.proxy(marshalled_from)
		to             = peer.proxy(marshalled_to)
		context        = peer.proxy(context)
		
		Distributed.pending_signals << [only_forward, from_generator, to, time, context]
	    end
	end

	@pending_signals = Queue.new
	class << self
	    attr_reader :pending_signals
	    def distributed_signals
		pending_signals.get(true).each do |only_forward, from_generator, to_generator, time, context|
		    from           = from_generator.new(context)
		    from.send(:time=, time)

		    from_generator.fired(from)

		    # only add the signalling if we own +to+
		    if to_generator.self_owned?
			Propagation.add_event_propagation(only_forward, [from], to_generator, context)
		    else
			# Call #fired and #signalling to make +from_generator+ look
			# like as if the event was really fired locally ...
			Distributed.update([from_generator.root_object, to_generator.root_object]) do
			    if only_forward then from_generator.forwarding(from, to_generator)
			    else from_generator.signalling(from, to_generator)
			    end
			end
		    end
		end
	    end
	end
	Control.event_processing << Distributed.method(:distributed_signals)
    end
end
