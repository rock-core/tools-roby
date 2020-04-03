# frozen_string_literal: true

module Roby
    # Exception raised when someone tries do commit an invalid transaction
    class InvalidTransaction < RuntimeError; end

    # A transaction is a special kind of plan. It allows to build plans in a separate
    # sandbox, and then to apply the modifications to the real plan (using
    # #commit_transaction), or to discard all modifications (using #discard)
    class Transaction < Plan
        # If true, an engine could execute tasks included in this plan. This is
        # alwxays false for transactions
        #
        # @return [Boolean]
        def executable?
            false
        end

        # If this is true, no mutating operation can be attempted on the transaction
        #
        # This is used during the commit process to verify that no new
        # modifications are applied to the transaction
        #
        # @see FrozenTransaction
        attr_predicate :frozen?

        # True if this transaction has been committed
        #
        # @see #finalized?
        attr_predicate :committed?

        # True if this transaction has either been discarded or committed
        #
        # @return [Boolean]
        # @see #committed?
        def finalized?
            !plan
        end

        # (see Plan#root_plan?)
        def root_plan?
            false
        end

        def extend_proxy_object(proxy, object, klass = object.class)
            proxy.extend Roby::Transaction::Proxying.proxying_module_for(klass)
        end

        def setup_and_register_proxy_task(proxy, task)
            validate_transaction_not_frozen

            proxy_tasks[task] = proxy
            extend_proxy_object(proxy, task)
            proxy.plan = self
            proxy.setup_proxy(task, self)
            register_task(proxy)
            if plan.mission_task?(task)
                add_mission_task(proxy)
            elsif plan.permanent_task?(task)
                add_permanent_task(proxy)
            end
            plan.find_all_plan_services(task).each do |original_srv|
                create_and_register_proxy_plan_service(original_srv)
            end

            proxy
        end

        def setup_and_register_proxy_event(proxy, event)
            validate_transaction_not_frozen

            proxy_events[event] = proxy
            extend_proxy_object(proxy, event)
            proxy.plan = self
            proxy.setup_proxy(event, self)
            register_event(proxy)
            add_permanent_event(proxy) if plan.permanent_event?(event)
            proxy
        end

        def setup_and_register_proxy_plan_service(proxy, plan_service)
            validate_transaction_not_frozen

            extend_proxy_object(proxy, plan_service)
            proxy.setup_proxy(plan_service, self)
            proxy.task = wrap_task(plan_service.to_task)
            add_plan_service(proxy)
            proxy
        end

        def create_and_register_proxy_task(object)
            validate_transaction_not_frozen

            proxy = object.dup
            setup_and_register_proxy_task(proxy, object)
            copy_object_relations(object, proxy, proxy_tasks)
            proxy
        end

        def create_and_register_proxy_event(object)
            validate_transaction_not_frozen

            proxy = object.dup
            setup_and_register_proxy_event(proxy, object)
            copy_object_relations(object, proxy, proxy_events)
            proxy
        end

        def create_and_register_proxy_plan_service(object)
            validate_transaction_not_frozen

            # Ensure the underlying task is wrapped
            proxy = object.dup
            setup_and_register_proxy_plan_service(proxy, object)
            proxy
        end

        def find_local_object_for_plan_object(object, proxy_map)
            if object.plan == self
                object
            elsif (proxy = proxy_map[object])
                proxy
            elsif !object.plan
                raise ArgumentError,
                      "#{object} has been removed from plan"
            elsif object.plan.template?
                add(object)
                object
            end
        end

        def find_local_object_for_task(object)
            find_local_object_for_plan_object(object, proxy_tasks)
        end

        def find_local_object_for_event(object)
            find_local_object_for_plan_object(object, proxy_events)
        end

        def find_local_object_for_plan_service(object)
            return unless (local_task = find_local_object_for_task(object.task))

            find_plan_service(local_task)
        end

        def wrap_plan_object(object, proxy_map)
            if object.plan != plan
                raise ArgumentError,
                      "#{object} is in #{object.plan}, "\
                      "this transaction #{self} applies on #{plan}"
            else
                object.create_transaction_proxy(self)
            end
        end

        def wrap_task(task, create: true)
            if (local_task = find_local_object_for_task(task))
                local_task
            elsif create
                wrap_plan_object(task, proxy_tasks)
            end
        end

        def wrap_event(event, create: true)
            if (local_event = find_local_object_for_event(event))
                local_event
            elsif create
                wrap_plan_object(event, proxy_events)
            end
        end

        def wrap_plan_service(plan_service, create: true)
            if (local_plan_service = find_local_object_for_plan_service(plan_service))
                local_plan_service
            elsif create
                plan_service.create_transaction_proxy(self)
            end
        end

        # Get the transaction proxy for +object+
        def wrap(object, create: true)
            if object.kind_of?(PlanService)
                wrap_plan_service(object, create: create)
            elsif object.respond_to?(:to_task)
                wrap_task(object, create: create)
            elsif object.respond_to?(:to_event)
                wrap_event(object, create: create)
            elsif object.respond_to?(:to_ary)
                object.map { |o| wrap(o, create: create) }
            elsif object.respond_to?(:each)
                raise ArgumentError,
                      "don't know how to wrap containers of class #{object.class}"
            else
                raise TypeError,
                      "don't know how to wrap #{object || 'nil'} of type "\
                      "#{object.class.ancestors}"
            end
        end

        def [](object, create: true)
            wrap(object, create: create)
        end

        def propose; end

        def edit
            yield if block_given?
        end

        # @api private
        #
        # Copies relations when importing a new subplan from the main plan
        #
        # @param [Hash<Relations::Graph,Relations::Graph>] relation graph
        #   mapping from the plan graphs to the transaction graphs
        # @param [Hash<PlanObject,PlanObject>] mappings
        #   mapping from the plan objects to the transaction objects
        def import_subplan_relations(graphs, mappings, proxy_map)
            graphs.each do |plan_g, self_g|
                plan_g.copy_subgraph_to(self_g, mappings)
                mappings.each do |plan_v, self_v|
                    # The method assumes that the plan objects are new. We are
                    # therefore done if there is the same number of relations in
                    # both plan and transactions
                    #
                    # It is NOT true in the general case as one can add extra
                    # relations in the transaction
                    if plan_g.in_degree(plan_v) != self_g.in_degree(self_v)
                        plan_g.each_in_neighbour(plan_v) do |plan_parent|
                            next if mappings.key?(plan_parent)

                            if (self_parent = proxy_map[plan_parent])
                                self_g.add_edge(
                                    self_parent, self_v,
                                    plan_g.edge_info(plan_parent, plan_v)
                                )
                            end
                        end
                    end

                    if plan_g.out_degree(plan_v) != self_g.out_degree(self_v)
                        plan_g.each_out_neighbour(plan_v) do |plan_child|
                            next if mappings.key?(plan_child)

                            if (self_child = proxy_map[plan_child])
                                self_g.add_edge(
                                    self_v, self_child,
                                    plan_g.edge_info(plan_v, plan_child)
                                )
                            end
                        end
                    end
                end
            end
        end

        # This method copies on +proxy+ all relations of +object+ for which
        # both ends of the relation are already in the transaction.
        def copy_object_relations(object, proxy, proxy_map)
            # Create edges between the neighbours that are really in the transaction
            object.each_relation do |rel|
                plan_graph = object.relation_graph_for(rel)
                trsc_graph = proxy.relation_graph_for(rel)

                plan_graph.each_in_neighbour(object) do |parent|
                    if (parent_proxy = proxy_map[parent])
                        trsc_graph.add_edge(
                            parent_proxy, proxy,
                            plan_graph.edge_info(parent, object)
                        )
                    end
                end
                plan_graph.each_out_neighbour(object) do |child|
                    if (child_proxy = proxy_map[child])
                        trsc_graph.add_edge(
                            proxy, child_proxy,
                            plan_graph.edge_info(object, child)
                        )
                    end
                end
            end
        end

        # Tests whether a plan object has a proxy in self
        #
        # Unlike {#wrap}, the provided object must be a plan object from the
        # transaction's underlying plan
        #
        # @param [Roby::Task] object the object to test for
        def has_proxy_for_task?(object)
            if object.plan != plan
                raise ArgumentError,
                      "#{object} is not in #{self}.plan (#{plan})"
            end
            proxy_tasks.key?(object)
        end

        # Tests whether an event has a proxy in self
        #
        # Unlike {#wrap}, the provided object must be a plan object from the
        # transaction's underlying plan
        #
        # @param [Roby::EventGenerator] object the object to test for
        def has_proxy_for_event?(object)
            if object.plan != plan
                raise ArgumentError,
                      "#{object} is not in #{self}.plan (#{plan})"
            end
            proxy_events.key?(object)
        end

        def restore_relation(proxy, relation)
            object = proxy.__getobj__

            proxy_children = proxy.child_objects(relation)
            object.child_objects(relation).each do |object_child|
                next unless (proxy_child = wrap(object_child, create: false))

                if proxy_children.include?(proxy_child)
                    relation.remove_edge(proxy, proxy_child)
                end
            end

            proxy_parents = proxy.parent_objects(relation)
            object.parent_objects(relation).each do |object_parent|
                next unless (proxy_parent = wrap(object_parent, create: false))

                if proxy_parents.include?(proxy_parent)
                    relation.remove_edge(parent, proxy_parent)
                end
            end

            added_objects.delete(proxy)
            proxy.discovered_relations.delete(relation)
            proxy.do_discover(relation, false)
        end

        # Removes an object from this transaction
        #
        # This does *not* remove the object from the underlying plan. Removing
        # objects directly is (at best) dangerous, and should be handled by
        # garbage collection.
        def remove_plan_object(object, proxy_map)
            validate_transaction_not_frozen

            object = may_unwrap(object)
            proxy  = proxy_map.delete(object)
            actual_plan = (proxy || object).plan

            if actual_plan != self
                raise InternalError,
                      "inconsistency: #{proxy || object} plan is #{actual_plan}, "\
                      "was expected to be #{self}"
            end
            [object, proxy]
        end

        def remove_task(task, timestamp = Time.now)
            unwrapped, proxy = remove_plan_object(task, proxy_tasks)
            if proxy
                unmarked_mission_tasks.delete(unwrapped)
                unmarked_permanent_tasks.delete(unwrapped)
                proxy.each_plan_child do |task_event_proxy|
                    remove_plan_object(task_event_proxy, proxy_events)
                end
            end
            super(proxy || task, timestamp)
        end

        def remove_free_event(event, timestamp = Time.now)
            unwrapped, proxy = remove_plan_object(event, proxy_events)
            unmarked_permanent_events.delete(unwrapped) if proxy
            super(proxy || event, timestamp)
        end

        def may_wrap(objects, create: true)
            if objects.respond_to?(:to_ary)
                objects.map { |obj| may_wrap(obj, create: create) }
            elsif objects.respond_to?(:each)
                raise ArgumentError,
                      "don't know how to wrap containers of class #{objects.class}"
            elsif objects.kind_of?(PlanObject)
                wrap(objects, create: create)
            else
                objects
            end
        end

        # If +object+ is in this transaction, may_unwrap will return the
        # underlying plan object. In all other cases, returns object.
        def may_unwrap(object)
            if object.respond_to?(:plan)
                if object.plan == self && object.respond_to?(:__getobj__)
                    object.__getobj__
                elsif object.plan == plan
                    object
                else
                    object
                end
            else object
            end
        end

        # The list of missions of the underlying plan that have been unmarked in
        # the transaction
        attr_reader :unmarked_mission_tasks
        # The list of permanent tasks of the underlying plan that have been unmarked in
        # the transaction
        attr_reader :unmarked_permanent_tasks
        # The list of permanent events of the underlying plan that have been unmarked in
        # the transaction
        attr_reader :unmarked_permanent_events
        # The plan this transaction applies on
        attr_reader :plan
        # The proxy objects built for tasks in this transaction
        attr_reader :proxy_tasks
        # The proxy objects built for events this transaction
        attr_reader :proxy_events
        # The option hash given at initialization
        attr_reader :options

        # The decision control object associated with this transaction. It is
        # in general plan.control
        def control
            plan.control
        end

        # Creates a new transaction which applies on +plan+
        def initialize(plan, options = {})
            raise ArgumentError, 'cannot create a transaction with no plan' unless plan

            @options = options
            @frozen = false
            @disable_proxying = false
            @invalid = false

            super()

            @plan = plan

            @proxy_tasks = {}
            @proxy_events = {}
            @unmarked_mission_tasks = Set.new
            @unmarked_permanent_tasks = Set.new
            @unmarked_permanent_events = Set.new

            plan.transactions << self
            plan.added_transaction(self)
        end

        # Calls the given block in the execution thread of the engine of the
        # underlying plan. If there is no engine attached to this plan, yields
        # immediately.
        #
        # See Plan#execute and ExecutionEngine#execute
        def execute(&block)
            plan.execute(&block)
        end

        def add_mission_task(t)
            validate_transaction_not_frozen

            unmarked_mission_tasks.delete(t.__getobj__) if t.transaction_proxy?
            super(t)
        end

        def add_permanent_task(t)
            validate_transaction_not_frozen

            unmarked_permanent_tasks.delete(t.__getobj__) if t.transaction_proxy?
            super(t)
        end

        def add_permanent_event(e)
            validate_transaction_not_frozen

            unmarked_permanent_events.delete(e.__getobj__) if e.transaction_proxy?
            super(e)
        end

        def add(objects)
            validate_transaction_not_frozen

            super(objects)
            self
        end

        def unmark_permanent_event(t)
            validate_transaction_not_frozen

            t = t.as_plan
            if (proxy = find_local_object_for_event(t))
                super(proxy)
            end

            t = may_unwrap(t)
            unmarked_permanent_events.add(t) if t.plan == plan
        end

        def unmark_permanent_task(t)
            validate_transaction_not_frozen

            t = t.as_plan
            if (proxy = find_local_object_for_task(t))
                super(proxy)
            end

            t = may_unwrap(t)
            unmarked_permanent_tasks.add(t) if t.plan == plan
        end

        def unmark_mission_task(t)
            validate_transaction_not_frozen

            t = t.as_plan
            if (proxy = find_local_object_for_task(t))
                super(proxy)
            end

            t = may_unwrap(t)
            unmarked_mission_tasks.add(t) if t.plan == plan
        end

        # The set of invalidation reasons registered with {#invalidate}. It is
        # cleared if the transaction is marked as valid again by calling
        # {#invalid=}.
        #
        # @return [Array<String>]
        attribute(:invalidation_reasons) { [] }

        # Marks this transaction as either invalid or valid. If it is marked as
        # valid, it clears {#invalidation_reasons}.
        def invalid=(flag)
            invalidation_reasons.clear unless flag
            @invalid = flag
        end

        # True if {#invalidate} has been called, and {#invalid=} has not been
        # called to clear the invalidation afterwards.
        def invalid?
            @invalid
        end

        # Tests if it is safe to commit this transaction
        #
        # @return [Boolean] it returns false if there are other transactions on
        #   top of it. They must be committed or discarded before this transaction
        #   can be committed or discarded. It also returns safe if if this
        #   transaction has been marked as invalid with {#invalidate}
        def valid_transaction?
            transactions.empty? && !invalid?
        end

        # Marks this transaction as valid
        def invalidate(reason = nil)
            self.invalid = true
            invalidation_reasons << [reason, caller(1)] if reason
            Roby.debug do
                "invalidating #{self}: #{reason}"
            end
        end

        # Tests if it is safe to commit this transaction
        #
        # @return [void]
        # @raise [InvalidTransaction] in all cases where {#valid_transaction?}
        #   returns false
        def check_valid_transaction
            return if valid_transaction?

            unless transactions.empty?
                raise InvalidTransaction, 'there is still transactions on top of this one'
            end

            message = invalidation_reasons.map do |reason, trace|
                "#{trace[0]}: #{reason}\n  #{trace[1..-1].join("\n  ")}"
            end.join("\n")
            raise InvalidTransaction, "invalid transaction: #{message}"
        end

        # @api private
        #
        # Apply the graph modifications returned by
        # {#compute_graph_modifications_for}
        def apply_graph_modifications(work_graphs, added, removed, updated)
            added.each do |graph, parent, child, info|
                work_graphs[graph].add_edge(parent, child, info)
            end
            removed.each do |graph, parent, child|
                work_graphs[graph].remove_edge(parent, child)
            end
            updated.each do |graph, parent, child, info|
                work_graphs[graph].set_edge_info(parent, child, info)
            end
        end

        # @api private
        #
        # Compute the graph modifications that are involving the given proxy
        #
        # It only computes the parent modifications involving objects that are
        # not proxies themselves. It computes the child modifications for every
        # child
        def compute_graph_modifications_for(
            proxy, new_relations, removed_relations, updated_relations
        )
            real_object = proxy.__getobj__
            proxy.partition_new_old_relations(
                :each_parent_object, include_proxies: false
            ) do |trsc_objects, rel, new, del, existing|
                trsc_graph = proxy.relation_graph_for(rel)
                plan_graph = proxy.__getobj__.relation_graph_for(rel)

                new.each do |task|
                    edge_info = trsc_graph.edge_info(trsc_objects[task], proxy)
                    new_relations << [plan_graph, task, real_object, edge_info]
                end
                del.each do |task|
                    removed_relations << [plan_graph, task, real_object]
                end
                existing.each do |task|
                    edge_info = trsc_graph.edge_info(trsc_objects[task], proxy)
                    if plan_graph.edge_info(task, real_object) != edge_info
                        updated_relations << [plan_graph, task, real_object, edge_info]
                    end
                end
            end

            proxy.partition_new_old_relations(
                :each_child_object
            ) do |trsc_objects, rel, new, del, existing|
                trsc_graph = proxy.relation_graph_for(rel)
                plan_graph = proxy.__getobj__.relation_graph_for(rel)

                new.each do |task|
                    edge_info = trsc_graph.edge_info(proxy, trsc_objects[task])
                    new_relations << [plan_graph, real_object, task, edge_info]
                end
                del.each do |task|
                    removed_relations << [plan_graph, real_object, task]
                end
                existing.each do |task|
                    edge_info = trsc_graph.edge_info(proxy, trsc_objects[task])
                    if plan_graph.edge_info(real_object, task) != edge_info
                        updated_relations << [plan_graph, real_object, task, edge_info]
                    end
                end
            end
        end

        # @api private
        #
        # This compute the triggers that shoul be applied if we commit this
        # transaction
        def compute_triggers_for_committed_transaction
            trigger_matches = {}
            plan.triggers.each do |tr|
                tr.each(self) do |t|
                    trigger_matches[t] = tr
                end
            end
            proxy_tasks.each do |obj, proxy|
                if (tr = trigger_matches.delete(proxy))
                    trigger_matches[obj] = tr unless tr === obj # already triggered
                end
            end
            trigger_matches
        end

        # @api private
        #
        # Apply the triggers as returned by
        # {#compute_triggers_for_committed_transaction}
        def apply_triggers_on_committed_transaction(triggered_matches)
            triggered_matches.each do |task, trigger|
                trigger.call(task)
            end
        end

        # Apply the modifications represented by self to the underlying plan
        # snippet in your redefinition if you do so.
        def apply_modifications_to_plan
            new_mission_tasks    = Set.new
            new_permanent_tasks  = Set.new
            new_permanent_events = Set.new

            added_relations   = []
            removed_relations = []
            updated_relations = []

            # We're doing a lot of modifications of this plan .. store some of
            # the sets we need for later, one part to keep them unchanged, one
            # part to make sure we don't do modify-while-iterate
            proxy_tasks = self.proxy_tasks.dup
            proxy_events = self.proxy_events.dup
            plan_services = self.plan_services.dup
            unmarked_mission_tasks = self.unmarked_mission_tasks.dup
            unmarked_permanent_tasks = self.unmarked_permanent_tasks.dup
            unmarked_permanent_events = self.unmarked_permanent_events.dup
            # We're taking care of the proxies first, so that we can merge the
            # transaction using Plan#merge!. However, this means that
            # #may_unwrap does not work after the first few steps. We therefore
            # have to store the object-to-proxy mapping
            real_objects = {}

            # We make a copy of all relation graphs, and update them with the
            # transaction data. The underlying plan graphs are not modified
            #
            # We do not #dup them because we don't want to dup the edge info.
            # Instead, we instanciate anew and merge. The add_vertex calls are
            # needed to make sure that the graph dups the in/out sets instead
            # of just copying them
            task_work_graphs, event_work_graphs =
                plan.class.instanciate_relation_graphs
            work_graphs = {}
            transaction_graphs = {}
            plan.each_task_relation_graph do |g|
                work_g = work_graphs[g] = task_work_graphs[g.class]
                g.each_vertex { |v| work_g.add_vertex(v) }
                work_g.merge(g)
                transaction_graphs[g] = task_relation_graph_for(g.class)
            end
            plan.each_event_relation_graph do |g|
                work_g = work_graphs[g] = event_work_graphs[g.class]
                g.each_vertex { |v| work_g.add_vertex(v) }
                work_g.merge(g)
                transaction_graphs[g] = event_relation_graph_for(g.class)
            end

            # First apply all changes related to the proxies to the underlying
            # plan. This adds some new tasks to the plan graph, but does not add
            # them to the plan itself
            #
            # Note that we need to do that in two passes. The first one keeps
            # the transaction unchanged, the second one removes the proxies from
            # the transaction. This is needed so that #commit_transaction sees
            # the graph unchanged
            proxy_objects = proxy_tasks.merge(proxy_events)

            proxy_objects.each do |object, proxy|
                real_objects[proxy] = object
                compute_graph_modifications_for(
                    proxy, added_relations, removed_relations, updated_relations
                )
                proxy.commit_transaction
            end
            proxy_tasks.dup.each do |object, proxy|
                if proxy.self_owned?
                    if mission_task?(proxy)
                        new_mission_tasks << object
                    elsif permanent_task?(proxy)
                        new_permanent_tasks << object
                    end
                end
                remove_task(proxy)
            end
            proxy_events.dup.each do |object, proxy|
                if proxy.root_object?
                    new_permanent_events << object if permanent_event?(proxy)
                    remove_free_event(proxy)
                end
            end

            work_graphs.each do |plan_g, work_g|
                work_g.merge(transaction_graphs[plan_g])
            end
            apply_graph_modifications(
                work_graphs, added_relations, removed_relations, updated_relations
            )

            begin
                validate_graphs(work_graphs.values)
            rescue StandardError => e
                raise e, "cannot apply #{self}: #{e.message}", e.backtrace
            end

            #### UNTIL THIS POINT we have not modified the underlying plan AT ALL
            # We DID update the transaction, though

            # Apply #commit_transaction on the remaining tasks
            tasks.each(&:commit_transaction)
            free_events.each(&:commit_transaction)

            # What is left in the transaction is the network of new tasks. Just
            # merge it
            plan.merge_transaction!(
                self, work_graphs,
                added_relations, removed_relations, updated_relations
            )

            # Update the plan services on the underlying plan. The only
            # thing we need to take care of is replacements and new
            # services. Other modifications will be applied automatically
            plan_services.each do |task, services|
                services.each do |srv|
                    if srv.transaction_proxy?
                        # Modified service. Might be moved to a new task
                        original = srv.__getobj__
                        # Do NOT use may_unwrap here ... See comments at the top
                        # of the method
                        task     = real_objects[task] || task
                        srv.commit_transaction
                        plan.move_plan_service(original, task) if original.task != task
                    elsif task.transaction_proxy?
                        # New service on an already existing task
                        srv.task = task.__getobj__
                        plan.add_plan_service(srv)
                    else
                        # New service on a new task
                        plan.add_plan_service(srv)
                    end
                end
            end

            new_mission_tasks.each { |t| plan.add_mission_task(t) }
            new_permanent_tasks.each { |t| plan.add_permanent_task(t) }
            new_permanent_events.each { |ev| plan.add_permanent_event(ev) }

            active_fault_response_tables.each do |tbl|
                plan.use_fault_response_table tbl.model, tbl.arguments
            end

            unmarked_permanent_events.each { |t| plan.unmark_permanent_event(t) }
            unmarked_permanent_tasks.each { |t| plan.unmark_permanent_task(t) }
            unmarked_mission_tasks.each { |t| plan.unmark_mission_task(t) }

            proxy_objects.each do |object, proxy|
                forwarder_module =
                    Transaction::Proxying.forwarder_module_for(object.model)
                proxy.extend forwarder_module
                proxy.__getobj__ = object
                proxy.__freeze__
            end
        end

        # Commit all modifications that have been registered
        # in this transaction
        def commit_transaction
            check_valid_transaction
            trigger_matches = compute_triggers_for_committed_transaction
            apply_modifications_to_plan
            apply_triggers_on_committed_transaction(trigger_matches)
            frozen!

            @committed = true
            committed_transaction
            plan.remove_transaction(self)
            @plan = nil

            yield if block_given?
        end

        # Hook called just after this transaction has been committed
        #
        # @return [void]
        def committed_transaction; end

        def enable_proxying
            @disable_proxying = false
        end

        def disable_proxying
            @disable_proxying = true
            return unless block_given?

            begin
                yield
            ensure
                @disable_proxying = false
            end
        end

        def proxying?
            !@frozen && !@disable_proxying
        end

        # Discards this transaction and all the transactions it is part of
        #
        # @return [void]
        def discard_transaction!
            transactions.dup.each(&:discard_transaction!)
            discard_transaction
        end

        # Discard all the modifications that have been registered
        # in this transaction
        #
        # @return [void]
        def discard_transaction
            unless transactions.empty?
                raise InvalidTransaction,
                      'there are still transactions on top of this one'
            end

            frozen!

            discarded_transaction
            plan.remove_transaction(self)
            @plan = nil
        end

        # Hook called just after this transaction has been discarded
        #
        # @return [void]
        def discarded_transaction; end

        def frozen!
            @frozen = true
        end

        # Clears this transaction
        #
        # A cleared transaction behaves as a new transaction on the same plan
        # @return [void]
        def clear
            unmarked_mission_tasks.clear
            unmarked_permanent_tasks.clear
            unmarked_permanent_events.clear
            proxy_tasks.each_value(&:clear_relations)
            proxy_tasks.clear
            proxy_events.each_value(&:clear_relations)
            proxy_events.clear
            super
        end

        # Hook called when a task included in self got finalized from {#plan}
        #
        # It invalidates the transaction and calls
        # DecisionControl#finalized_plan_task(self, event) for further actions
        #
        # @param [Task] task the finalized task represented by its proxy in self
        # @return [void]
        def finalized_plan_task(task)
            proxied_task = task.__getobj__

            invalidate("task #{task} has been removed from the plan")
            discard_modifications(proxied_task)
            control.finalized_plan_task(self, task)
        end

        # Hook called when an event included in self got finalized from {#plan}
        #
        # It invalidates the transaction and calls
        # DecisionControl#finalized_plan_event(self, event) for further actions
        #
        # @param [EventGenerator] event the finalized event represented by
        #        its proxy in self
        # @return [void]
        def finalized_plan_event(event)
            proxied_event = event.__getobj__

            invalidate("event #{event} has been removed from the plan")
            discard_modifications(proxied_event)
            control.finalized_plan_event(self, event)
        end

        # Hook called when a relation is added between plan objects that are
        # present in the transaction
        #
        # If the new relation is not present in the transaction as well, it
        # invalidates the transaction and calls
        # DecisionControl#adding_plan_relation(self, parent, child, relations,
        # info) for further action
        #
        # @param [PlanObject] parent the parent object represented by its proxy in self
        # @param [PlanObject] child the child object represented by its proxy in self
        # @param [Array<Relations::Graph>] relations the graphs in which a relation
        #   has been added
        # @param [Object] info the added information for the new edges
        #   (relation specific)
        # @return [void]
        def adding_plan_relation(parent, child, relations, info)
            missing_relations = relations.find_all do |rel|
                !parent.child_object?(child, rel)
            end

            unless missing_relations.empty?
                invalidate(
                    "plan added a relation #{parent} -> #{child} "\
                    "in #{relations} with info #{info}"
                )
                control.adding_plan_relation(self, parent, child, relations, info)
            end

            nil
        end

        # Hook called when a relation is removed between plan objects that are
        # present in the transaction
        #
        # If the removed relation is still present in the transaction as well, it
        # invalidates the transaction and calls
        # DecisionControl#removing_plan_relation(self, parent, child, relations, info)
        #       for further action
        #
        # @param [PlanObject] parent the parent object represented by its proxy in self
        # @param [PlanObject] child the child object represented by its proxy in self
        # @param [Array<Relations::Graph>] relations the graphs in which a relation
        #   has been added
        # @return [void]
        def removing_plan_relation(parent, child, relations)
            present_relations = relations.find_all do |rel|
                parent.child_object?(child, rel)
            end

            unless present_relations.empty?
                invalidate(
                    "plan removed a relation #{parent} -> #{child} in #{relations}"
                )
                control.removing_plan_relation(self, parent, child, relations)
            end

            nil
        end

        # @api private
        #
        # Internal delegation from the matchers to the plan object to determine
        # the 'right' query algorithm
        def query_result_set(matcher)
            Queries::TransactionQueryResult.from_transaction(self, matcher)
        end

        def discard_modifications(object)
            if object.respond_to?(:to_task)
                remove_task(object.to_task)
            else
                remove_event(object.to_task)
            end
        end

        # Exception raised when a mutation operation is attempted on a transaction
        # that has been committed or discarded
        class FrozenTransaction < RuntimeError
        end

        # @api private
        #
        # Method called before any mutating operation to verify that the
        # transaction can actually be modified - i.e. that it has not been
        # commited or discarded yet
        #
        # @raise FrozenTransaction
        def validate_transaction_not_frozen
            if frozen?
                raise FrozenTransaction,
                      "transaction #{self} has been either committed or discarded. "\
                      'No modification allowed'
            end

            nil
        end
    end
end
