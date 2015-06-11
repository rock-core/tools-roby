module Roby
    module Distributed

    # PeerServer objects are the objects which act as servers for the plan
    # managers we are connected on, i.e. it will process the messages sent by
    # those remote plan managers.
    #
    # The client part, that is the part which actually send the messages, is
    # a Peer object accessible through the Peer#peer attribute.
    class PeerServer
	include DRbUndumped

	# The Peer object we are associated to
	attr_reader :peer

        def connection_space
            peer.connection_space
        end

        # The set of triggers our peer has added to our plan
	attr_reader :triggers

        # Create a PeerServer object for the given peer
	def initialize(peer)
	    @peer	    = peer 
	    @triggers	    = Hash.new
	end

	def to_s # :nodoc:
            "PeerServer:#{remote_name}" 
        end

        # Activate any trigger that may exist on +objects+
        # It sends the PeerServer#triggered message for each objects that are
        # actually matching a registered trigger.
	def trigger(*objects)
	    triggers.each do |id, (matcher, triggered)|
		objects.each do |object|
		    if !triggered.include?(object) && matcher === object
			triggered << object
			peer.transmit(:triggered, id, object)
		    end
		end
	    end
	end

	# The name of the local ConnectionSpace object we are acting on
	def local_name; peer.local_name end
	# The name of the remote peer
	def remote_name; peer.remote_name end
	
	# The plan object which is used as a facade for our peer
	def plan; peer.connection_space.plan end

	# Applies +matcher+ on the local plan and sends back the result
	def query_result_set(query)
	    plan.query_result_set(peer.local_object(query)).
		delete_if { |obj| !obj.distribute? }
	end

	# The peers asks to be notified if a plan object which matches
	# +matcher+ changes
	def add_trigger(id, matcher)
	    triggers[id] = [matcher, (triggered = ValueSet.new)]
	    Distributed.info "#{remote_name} wants notification on #{matcher} (#{id})"

	    peer.queueing do
		matcher.each(plan) do |task|
		    if !triggered.include?(task)
			triggered << task
			peer.transmit(:triggered, id, task)
		    end
		end
	    end
	    nil
	end

	# Remove the trigger +id+ defined by this peer
	def remove_trigger(id)
	    Distributed.info "#{remote_name} removed #{id} notification"
	    triggers.delete(id)
	    nil
	end

        # Message received when +task+ has matched the trigger referenced by +id+
	def triggered(id, task)
	    peer.triggered(id, task) 
	    nil
	end

	# Send the neighborhood of +distance+ hops around +object+ to the peer
	def discover_neighborhood(object, distance)
	    object = peer.local_object(object)
	    edges = object.neighborhood(distance)
	    if object.respond_to?(:each_plan_child)
		object.each_plan_child do |plan_child|
		    edges += plan_child.neighborhood(distance)
		end
	    end

	    # Replace the relation graphs by their name
	    edges.delete_if do |rel, from, to, info|
		!(rel.distribute? && from.distribute? && to.distribute?)
	    end
	    edges
	end

        # Message received to update our view of the remote robot state.
        def state_update(new_state)
            peer.state = new_state
            nil
        end

        # Message received to announce that the internal data of +task+ is
        # now +data+.
        def updated_data(task, data)
            proxy = peer.local_object(task)
            proxy.instance_variable_set("@data", peer.proxy(data))
            nil
        end

        # Message received to announce that the arguments of +task+ have
        # been modified. +arguments+ is a hash containing only the new
        # values.
        def updated_arguments(task, arguments)
            proxy = peer.local_object(task)
            arguments = peer.proxy(arguments)
            Distributed.update(proxy) do
                proxy.arguments.merge!(arguments || {})
            end
            nil
        end

        # A set of events which have been received by #event_fired. This
        # cache in cleaned up by PlanCacheCleanup#finalized_event when the
        # associated generator is finalized.
        #
        # This cache is used to merge the events between the firing step
        # (event_fired) and the propagation steps (add_event_propagation).
        # Without it, different Event objects at the various method calls.
        attribute(:pending_events) { Hash.new }

        # Creates an Event object for +generator+, with the given argument
        # as parameters, or returns an already existing one
        def event_for(generator, event_id, time, context)
            id, event = pending_events[generator]
            if id && id == event_id
                return event
            end
            
            event = generator.new(context)
            event.send(:time=, time)
            if generator.respond_to?(:task)
                generator.task.update_task_status(event)
            end
            pending_events[generator] = [event_id, event]
            event
        end

        # Message received when the +marshalled_from+ generator fired an
        # event, with the given event id, time and context.
        def event_fired(marshalled_from, event_id, time, context)
            from_generator = peer.local_object(marshalled_from)
            context	       = peer.local_object(context)

            event = event_for(from_generator, event_id, time, context)

            event.send(:propagation_id=, from_generator.plan.engine.propagation_id)
            from_generator.instance_variable_set("@happened", true)
            from_generator.fired(event)
            from_generator.call_handlers(event)

            nil
        end

        # Message received when the +marshalled_from+ generator has either
        # been forwarded (only_forward = true) or signals (only_forward =
        # false) the +marshalled_to+ generator. The remaining information
        # describes the event itself.
        def event_add_propagation(only_forward, marshalled_from, marshalled_to, event_id, time, context)
            from_generator  = peer.local_object(marshalled_from)
            to_generator	= peer.local_object(marshalled_to)
            context         = peer.local_object(context)

            event		= event_for(from_generator, event_id, time, context)

            # Only add the signalling if we own +to+
            if to_generator.self_owned?
                to_generator.plan.engine.add_event_propagation(only_forward, [event], to_generator, event.context, nil)
            else
                # Call #signalling or #forwarding to make
                # +from_generator+ look like as if the event was really
                # fired locally ...
                Distributed.update_all([from_generator.root_object, to_generator.root_object]) do
                    if only_forward then from_generator.forwarding(event, to_generator)
                    else from_generator.signalling(event, to_generator)
                    end
                end
            end

            nil
        end

        # Message received when +task+ has become a mission (flag = true),
        # or has become a non-mission (flag = false) in +plan+.
        def plan_set_mission(plan, task, flag)
            plan = peer.local_object(plan)
            task = peer.local_object(task)
            if plan.owns?(task)
                if flag
                    plan.add_mission(task)
                else
                    plan.remove_mission(task)
                end
            else
                task.mission = flag
            end
            nil
        end

        # Message received when the set of tasks +m_tasks+ has been
        # added by the remote plan. +m_relations+ describes the
        # internal relations between elements of +m_tasks+. It is in a
        # format suitable for PeerServer#set_relations.
        def plan_add(plan, m_tasks, m_relations)
            Distributed.update(plan = peer.local_object(plan)) do
                tasks = peer.local_object(m_tasks).to_value_set
                Distributed.update_all(tasks) do 
                    plan.add(tasks)
                    m_relations.each_slice(2) do |obj, rel|
                        set_relations(obj, rel)
                    end
                end
            end
            nil
        end

        # Message received when +m_from+ has been replaced by +m_to+ in the
        # plan
        def plan_replace(plan, m_from, m_to)
            Distributed.update(plan = peer.local_object(plan)) do
                from, to = peer.local_object(m_from), peer.local_object(m_to)

                Distributed.update_all([from, to]) { plan.replace(from, to) }

                # Subscribe to the new task if the old task was subscribed
                # +from+ will be unsubscribed when it is finalized
                if peer.subscribed?(from) && !peer.subscribed?(to)
                    peer.subscribe(to)
                    nil
                end
            end
            nil
        end

        # Message received when +object+ has been removed from +plan+
        def plan_remove_object(plan, object)
            if local = peer.local_object(object, false)
                # Beware, transaction proxies have no 'plan' attribute
                plan = peer.local_object(plan)
                Distributed.update(plan) do
                    Distributed.update(local) do
                        plan.remove_object(local)
                    end
                end
                local.forget_peer(peer)
            end

        rescue ArgumentError => e
            if e.message =~ /has not been included in this plan/
                Roby::Distributed.warn "filtering the 'not included in this plan bug'"
            else
                raise
            end
        end

        # Message received when a relation graph has been updated. +op+ is
        # either +add_child_object+ or +remove_child_object+ and describes
        # what relation modification should be done. The two plan objects
        # +m_from+ and +m_to+ are respectively linked or unlinked in the
        # relation +m_rel+, with the given information object in case of a
        # new relation.
        def update_relation(plan, m_from, op, m_to, m_rel, m_info = nil)
            if plan
                Roby::Distributed.update(peer.local_object(plan)) { update_relation(nil, m_from, op, m_to, m_rel, m_info) }
            else
                from, to = 
                    peer.local_object(m_from, false), 
                    peer.local_object(m_to, false)

                if !from
                    return unless to && (to.self_owned? || to.subscribed?)
                    from = peer.local_object(m_from)
                elsif !to
                    return unless from && (from.self_owned? || from.subscribed?)
                    to   = peer.local_object(m_to)
                end

                rel = peer.local_object(m_rel)
                Roby::Distributed.update_all([from.root_object, to.root_object]) do
                    if op == :add_child_object
                        from.add_child_object(to, rel, peer.local_object(m_info))
                    elsif op == :remove_child_object
                        from.remove_child_object(to, rel)
                    end
                end
            end
            nil
        end

        # Message received when an error occured on the remote side, if
        # this error cannot be recovered.
        def fatal_error(error, msg, args)
            Distributed.fatal "remote reports #{peer.local_object(error)} while processing #{msg}(#{args.join(", ")})"
            disconnect
        end

        # Message received when our peer is closing the connection
        def disconnect
            Distributed.info "#{connection_space}: received disconnection request from #{peer}"
            peer.disconnected
            nil
        end

        # True the current thread is processing a remote request
        attr_predicate :processing?, true
        # True if the current thread is processing a remote request, and if it is a callback
        attr_predicate :processing_callback?, true
        # True if we have already queued a +completed+ message for the message being processed
        attr_predicate :queued_completion?, true
        # The ID of the message we are currently processing
        attr_accessor :current_message_id

        # Message received when the first half of a synchro point is
        # reached. See Peer#synchro_point.
        def synchro_point
            peer.transmit(:done_synchro_point)
            nil
        end
        # Message received when the synchro point is finished.
        def done_synchro_point; end

        # Message received to describe a group of consecutive calls that
        # have been completed, when all those calls return nil. This is
        # simply an optimization of the communication protocol, as most
        # remote calls return nil.
        #
        # +from_id+ is the ID of the first call of the group and +to_id+
        # the last. Both are included in the group.
        def completion_group(from_id, to_id)
            for id in (from_id..to_id)
                completed(nil, nil, id)
            end
            nil
        end

        # Message received when a given call, identified by its ID, has
        # been processed on the remote peer.  +result+ is the value
        # returned by the method, +error+ an exception object (if an error
        # occured).
        def completed(result, error, id)
            if peer.completion_queue.empty?
                result = Exception.exception("something fishy: got completion message for ID=#{id} but the completion queue is empty")
                error  = true
                call_spec = nil
            else
                call_spec = peer.completion_queue.pop
                if call_spec.message_id != id
                    result = Exception.exception("something fishy: ID mismatch in completion queue (#{call_spec.message_id} != #{id}")
                    error  = true
                    call_spec = nil
                end
            end

            if error
                if call_spec && thread = call_spec.waiting_thread
                    result = peer.local_object(result)
                    thread.raise result
                else
                    Roby::Distributed.fatal "fatal error in communication with #{peer}: #{result.full_message}"
                    Roby::Distributed.fatal "disconnecting ..."
                    if peer.connected?
                        peer.disconnect
                    elsif !peer.disconnected?
                        peer.disconnected!
                    end
                end

            elsif call_spec
                peer.call_attached_block(call_spec, result)
            end

            nil
        end

        # Queue a completion message for our peer. This is usually done
        # automatically in #demux, but it is useful to do it manually in
        # certain conditions, for instance in PeerServer#execute
        #
        # In #execute, the control thread -> RX thread context switch is
        # not immediate. Therefore, it is possible that events are queued
        # by the control thread while the #completed message is not.
        # #completed! both queues the message *and* makes sure that #demux
        # won't.
        def completed!(result, error)
            if queued_completion?
                raise "already queued the completed message"
            else
                Distributed.debug { "done, returns #{'error ' if error}#{result || 'nil'} in completed!" }
                self.queued_completion = true
                peer.queue_call false, :completed, [result, error, current_message_id]
            end
        end

        # call-seq:
        #	execute { ... }
        #
        # Executes the given block in the control thread and return when the block
        # has finished its execution. This method can be called only when serving
        # a remote call.
        def execute
            if !processing?
                return yield
            end

            peer.engine.execute do
                error = nil
                begin
                    result = yield
                rescue Exception => error
                end
                completed!(error || result, !!error, peer.current_message_id)
            end
        end

        # Message sent when our remote peer requests that we create a local
        # representation for one of its objects. It therefore creates a
        # sibling for +marshalled_object+, which is a representation of a
        # distributed object present on our peer.
        #
        # It calls #created_sibling on +marshalled_object+ with the new
        # created sibling, to allow for specific operations to be done on
        # it.
        def create_sibling(marshalled_object)
            object_remote_id = peer.remote_object(marshalled_object)
            if sibling = peer.proxies[object_remote_id]
                raise ArgumentError, "#{marshalled_object} has already a sibling (#{sibling})"
            end

            sibling = marshalled_object.sibling(peer)
            peer.subscriptions << object_remote_id
            marshalled_object.created_sibling(peer, sibling)
            nil
        end

        # Message received when +owner+ is a peer which now owns +object+
        def add_owner(object, owner)
            peer.local_object(object).add_owner(peer.local_object(owner), false)
            nil
        end
        # Message received when +owner+ does not own +object+ anymore
        def remove_owner(object, owner)
            peer.local_object(object).remove_owner(peer.local_object(owner), false)
            nil
        end
        # Message received before #remove_owner, to verify if the removal
        # operation can be done or not.
        def prepare_remove_owner(object, owner)
            peer.local_object(object).prepare_remove_owner(peer.local_object(owner))
            nil
        rescue
            $!
        end

        # Called by the peer to subscribe on +object+. Returns an array which
        # is to be fed to #demux to update the object relations on the remote
        # host
        #
        # In case of distributed transaction, it is forbidden to subscribe to a
        # proxy without having subscribed to the proxied object first. This
        # method will thus subscribe to both at the same time. Peer#subscribe
        # is supposed to do the same
        def subscribe_plan_object(object)
            if object.kind_of?(Transaction::Proxying) && object.__getobj__.self_owned?
                subscribe_plan_object(object.__getobj__)
            end
            set_relations_commands(object)
        end

        # The peer wants to subscribe to our main plan
        def subscribe_plan(sibling)
            added_sibling(peer.connection_space.plan.remote_id, sibling)
            peer.transmit(:subscribed_plan, peer.connection_space.plan.remote_id)
            subscribe(peer.connection_space.plan)
        end

        # Called by our peer because it has subscribed us to its main plan
        def subscribed_plan(remote_plan_id)
            peer.proxies[remote_plan_id] = peer.connection_space.plan
            peer.remote_plan = remote_plan_id
        end

        # Subscribe the remote peer to changes on +object+. +object+ must be
        # an object owned locally.
        def subscribe(m_object)
            if !(local_object = peer.local_object(m_object, false))
                raise OwnershipError, "no object for #{m_object}"
            elsif !local_object.self_owned?
                raise OwnershipError, "not owner of #{local_object}"
            end

            # We put the subscription process outside the communication
            # thread so that the remote peer can send back the siblings it
            # has created
            peer.queueing do
                peer.transmit(:subscribed, [local_object])

                case local_object
                when PlanObject
                    if !local_object.root_object?
                        raise ArgumentError, "cannot subscribe to non-root objects"
                    end
                    subscribe_plan_object(local_object)

                when Plan
                    tasks, events = local_object.known_tasks, local_object.free_events
                    tasks.delete_if    { |t| !t.distribute? }
                    events.delete_if   { |t| !t.distribute? }

                    peer.transmit(:discover_plan, local_object, tasks, events)
                    tasks.each  { |obj| subscribe_plan_object(obj) }
                    events.each { |obj| subscribe_plan_object(obj) }
                end
            end

            local_object.remote_id
        end
        
        # Called by the remote host because it has subscribed us to a plan
        # (a set of tasks and events).
        def discover_plan(marshalled_plan, m_tasks, m_events)
            plan = peer.local_object(marshalled_plan)
            Distributed.update(plan) do
                peer.local_object(m_tasks)
                peer.local_object(m_events)
            end
            nil
        end

        # Called by the remote peer to announce that it has created the
        # given siblings. +siblings+ is a remote_drbobject => local_object
        # hash
        #
        # It is also used by BasicObject#sibling_of to register a new
        # sibling
        def added_sibling(local_id, remote_id)
            local_id.local_object.add_sibling_for(peer, remote_id)
            nil
        end

        # Called by the remote peer to announce that it has removed the
        # given siblings. +objects+ is the list of local objects.
        #
        # It is also used by BasicObject#forget_peer to remove references
        # to an old sibling
        def removed_sibling(local_id, remote_id)
            local_object = local_id.local_object
            sibling = local_object.remove_sibling_for(peer, remote_id)

            # It is fine to remove a sibling twice: you nay for instance
            # decide in both sides that the sibling should be removed (for
            # instance during the disconnection process)
            if sibling && sibling != remote_id
                raise "removed sibling #{sibling} for #{local_id} on peer #{peer} does not match the provided remote id (#{remote_id})"
            end

            unless local_object.remotely_useful?
                Distributed.removed_objects.delete(local_object)
            end
        end

        # Called by the remote peer to announce that is has subscribed us to +objects+
        def subscribed(objects)
            # Register the subscription
            objects.each do |object|
                peer.subscriptions << peer.remote_object(object)
            end
            # Create the proxies
            peer.local_object(objects)
            nil
        end

        # Sends to the peer the set of relations needed to copy the state of +plan_object+
        # on the remote peer.
        def set_relations_commands(plan_object)
            peer.transmit(:set_relations, plan_object, Distributed.relations_of(plan_object))

            if plan_object.respond_to?(:each_plan_child)
                plan_object.each_plan_child do |plan_child|
                    peer.transmit(:set_relations, plan_child, Distributed.relations_of(plan_child))
                end
            end
        end

        # Sets the relation of +objects+ according to the description in +relations+.
        # See #relations_of for how +relations+ is formatted
        #
        # Note that any relation not listed in +relations+ will actually be
        # *removed* from the plan. Therefore, if +relations+ is empty, then
        # all relations of +object+ are removed.
        def set_relations(object, relations)
            object    = peer.local_object(object)
            relations = peer.local_object(relations)

            Distributed.update(object.root_object) do
                all_parents  = Hash.new { |h, k| h[k] = ValueSet.new }
                all_children = Hash.new { |h, k| h[k] = ValueSet.new }
                
                # Add or update existing relations
                relations.each_slice(3) do |graph, parents, children|
                    all_objects = parents.map { |p, _| p } + children.map { |c, _| c }
                    Distributed.update_all(all_objects) do
                        parents.each_slice(2) do |parent, info|
                            next unless parent
                            all_parents[graph] << parent

                            if graph.linked?(parent, object)
                                parent[object, graph] = info
                            else
                                Distributed.update(parent.root_object) do
                                    parent.add_child_object(object, graph, info)
                                end
                            end
                        end
                        children.each_slice(2) do |child, info|
                            next unless child
                            all_children[graph] << child

                            if graph.linked?(object, child)
                                object[child, graph] = info
                            else
                                Distributed.update(child.root_object) do
                                    object.add_child_object(child, graph, info)
                                end
                            end
                        end
                    end
                end

                Distributed.each_object_relation(object) do |rel|
                    # Remove relations that do not exist anymore
                    #
                    # If the other end of this relation cannot be seen by
                    # our remote peer, keep it: it means that the relation
                    # is a local-only annotation this pDB has added to the
                    # task
                    (object.parent_objects(rel).to_value_set - all_parents[rel]).each do |p|
                        # See comment above
                        next unless p.distribute?
                        Distributed.update_all([p.root_object, object.root_object]) do
                            p.remove_child_object(object, rel)
                        end
                    end
                    (object.child_objects(rel).to_value_set - all_children[rel]).each do |c|
                        # See comment above
                        next unless c.distribute?
                        Distributed.update_all([c.root_object, object.root_object]) do
                            object.remove_child_object(c, rel)
                        end
                    end
                end
            end

            nil
        end

        # Message received when the 'prepare' stage of the transaction
        # commit is requested.
        def transaction_prepare_commit(trsc)
            trsc = peer.local_object(trsc)
            peer.connection_space.transaction_prepare_commit(trsc)
            trsc.freezed!
            nil
        end
        # Message received when a transaction commit is requested.
        def transaction_commit(trsc)
            trsc = peer.local_object(trsc)
            peer.connection_space.transaction_commit(trsc)
            nil
        end
        # Message received when a transaction commit is to be abandonned.
        def transaction_abandon_commit(trsc, error)
            trsc = peer.local_object(trsc)
            peer.connection_space.transaction_abandon_commit(trsc, error)
            nil
        end
        # Message received when a transaction discard is requested.
        def transaction_discard(trsc)
            trsc = peer.local_object(trsc)
            peer.connection_space.transaction_discard(trsc)
            nil
        end
        # Message received when the transaction edition token is given to
        # this plan manager.
        def transaction_give_token(trsc, needs_edition)
            trsc = peer.local_object(trsc)
            trsc.edit!(needs_edition)
            nil
        end
    end

    end
end

