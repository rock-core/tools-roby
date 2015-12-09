module Roby
    # Exception raised when someone tries do commit an invalid transaction
    class InvalidTransaction < RuntimeError; end

    # A transaction is a special kind of plan. It allows to build plans in a separate
    # sandbox, and then to apply the modifications to the real plan (using #commit_transaction), or
    # to discard all modifications (using #discard)
    class Transaction < Plan
	# If true, an engine could execute tasks included in this plan. This is
        # alwxays false for transactions
        #
        # @return [Boolean]
	def executable?; false end

        # If this is true, no new proxies can be created on the transaction.
        # This is used during the commit process to verify that no new
        # modifications are applied to the transaction
        attr_predicate :frozen?

        # True if this transaction has been committed
        #
        # @see #finalized?
        attr_predicate :committed?

        # True if this transaction has either been discarded or committed
        #
        # @return [Boolean]
        # @see #committed?
	def finalized?; !plan end

        def setup_proxy(proxy, object, klass = object.class)
            proxy.extend Roby::Transaction::Proxying.proxying_module_for(klass)
            proxy.setup_proxy(object, self)
            proxy
        end

        def setup_and_register_proxy(proxy, object)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?

            if proxy.root_object?
                if proxy.class == Roby::PlanService
                else add(proxy)
                end
            end

            proxy = setup_proxy(proxy, object)
            proxy_objects[object] = proxy
	    copy_object_relations(object, proxy)

            if services = plan.plan_services[object]
                services.each do |original_srv|
                    create_and_register_plan_service_proxy(original_srv)
                end
            end

	    proxy
        end

        def create_and_register_plan_service_proxy(object)
            proxy = object.dup
            setup_proxy(proxy, object)

            if !underlying_proxy = proxy_objects[object.to_task]
                raise InternalError, "no proxy for #{object.to_task}, there should be one at this point"
            end
            proxy.task = underlying_proxy
            add_plan_service(proxy)
        end

        def create_and_register_proxy(object)
            proxy = object.dup(plan: self)
            setup_and_register_proxy(proxy, object)
        end

	def do_wrap(object) # :nodoc:
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?

	    if proxy = proxy_objects[object]
                return proxy
            elsif !object.root_object?
                do_wrap(object.root_object)
                if !(proxy = proxy_objects[object])
                    raise InternalError, "#{object} should have been wrapped but is not"
                end
                return proxy
            else
                create_and_register_proxy(object)
            end
	end

	def propose; end
	def edit
	    yield if block_given?
	end

	# This method copies on +proxy+ all relations of +object+ for which
	# both ends of the relation are already in the transaction.
	def copy_object_relations(object, proxy)
            # Create edges between the neighbours that are really in the transaction
            object.each_relation do |rel|
                object.each_parent_object(rel) do |parent|
                    if parent_proxy = self[parent, false]
                        parent_proxy.add_child_object(proxy, rel, parent[object, rel])
                    end
                end

                object.each_child_object(rel) do |child|
                    if child_proxy = self[child, false]
                        proxy.add_child_object(child_proxy, rel, object[child, rel])
                    end
                end
            end
	end

        # Tests whether a plan object has a proxy in self
        #
        # Unlike {#wrap}, the provided object must be a plan object from the
        # transaction's underlying plan
        #
        # @param [Roby::PlanObject] object the object to test for
        def has_proxy_for?(object)
            if object.plan != self.plan
                raise ArgumentError, "#{object} is not in #{self}.plan (#{plan})"
            end
            proxy_objects.has_key?(object)
        end

	# Get the transaction proxy for +object+
	def wrap(object, create = true)
            if object.kind_of?(PlanService)
                PlanService.get(wrap(object.task))
	    elsif object.kind_of?(PlanObject)
		if object.plan == self
                    return object
		elsif proxy = proxy_objects[object]
                    return proxy
                elsif !object.plan
                    raise ArgumentError, "#{object} has been removed from plan"
                elsif object.plan.template?
                    add(object)
                    return object
		elsif create
		    if object.plan != self.plan
			raise ArgumentError, "#{object} is in #{object.plan}, this transaction #{self} applies on #{self.plan}"
                    end

                    wrapped = do_wrap(object)
                    if object.respond_to?(:to_task) && plan.mission?(object)
                        add_mission_task(wrapped)
                    elsif plan.permanent?(object)
                        if object.respond_to?(:to_task)
                            add_permanent_task(wrapped)
                        else
                            add_permanent_event(wrapped)
                        end
                    end
                    return wrapped
		end
		nil
	    elsif object.respond_to?(:to_ary) 
		object.map { |o| wrap(o, create) }
            elsif object.respond_to?(:each)
                raise ArgumentError, "don't know how to wrap containers of class #{object.class}"
	    else
		raise TypeError, "don't know how to wrap #{object || 'nil'} of type #{object.class.ancestors}"
	    end
	end
        def [](*args)
            wrap(*args)
        end

	def restore_relation(proxy, relation)
	    object = proxy.__getobj__

            proxy_children = proxy.child_objects(relation)
            object.child_objects(relation).each do |object_child| 
                next unless proxy_child = wrap(object_child, false)
                if proxy_children.include?(proxy_child)
                    relation.remove_edge(proxy, proxy_child)
                end
            end

            proxy_parents = proxy.parent_objects(relation)
            object.parent_objects(relation).each do |object_parent| 
                next unless proxy_parent = wrap(object_parent, false)
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
	def remove_object(object)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?

	    object = may_unwrap(object)
            proxy  = proxy_objects.delete(object)
            actual_plan = (proxy || object).plan

            if actual_plan != self
                raise InternalError, "inconsistency: #{proxy || object} plan is #{actual_plan}, was expected to be #{self}"
            end

            if proxy
                discarded_tasks.delete(object)
                auto_tasks.delete(object)
                if proxy.respond_to?(:each_plan_child)
                    proxy.each_plan_child do |child_proxy|
                        remove_object(child_proxy)
                    end
                end
            end

            proxy ||= object
            if proxy.root_object?
                super(proxy)
            end
            self
	end

	def may_wrap(objects, create = true)
            if objects.respond_to?(:to_ary)
                objects.map { |obj| may_wrap(obj, create) }
            elsif objects.respond_to?(:each)
                raise ArgumentError, "don't know how to wrap containers of class #{objects.class}"
            elsif objects.kind_of?(PlanObject)
                wrap(objects, create)
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
		elsif object.plan == self.plan
		    object
		else
		    object
		end
	    else object
	    end
	end

	# The list of discarded
	attr_reader :discarded_tasks
	# The list of permanent tasks that have been auto'ed
	attr_reader :auto_tasks
	# The plan this transaction applies on
	attr_reader :plan
	# The proxy objects built for this transaction
	attr_reader :proxy_objects
        # The option hash given at initialization
	attr_reader :options

        # The decision control object associated with this transaction. It is
        # in general plan.control
        def control; plan.control end

	# Creates a new transaction which applies on +plan+
	def initialize(plan, options = {})
            if !plan
                raise ArgumentError, "cannot create a transaction with no plan"
            end

	    @options = options
            @frozen = false
            @disable_proxying = false
            @invalid = false

	    super()

	    @plan   = plan

	    @proxy_objects      = Hash.new
	    @discarded_tasks    = Set.new
	    @auto_tasks	        = Set.new

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

	def discover_neighborhood(object)
            stack  = object.transaction_stack
            object = object.real_object
            while stack.size > 1
                plan = stack.pop
                next_plan = stack.last

                next_plan[object]
                object.each_relation do |rel|
                    object.each_parent_object(rel) { |obj| next_plan[obj] }
                    object.each_child_object(rel)  { |obj| next_plan[obj] }
                end
                object = next_plan[object]
            end
            nil
	end

	def replace(from, to)
	    # Make sure +from+, its events and all the related tasks and events
	    # are in the transaction
	    discover_neighborhood(from)
	    from.each_event do |ev|
		discover_neighborhood(ev)
	    end

	    super(from, to)
	end

	def add_mission_task(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?
	    if proxy = self[t, false]
		discarded_tasks.delete(may_unwrap(proxy))
	    end
	    super(t)
	end

	def add_permanent_task(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?
	    if proxy = self[t, false]
		auto_tasks.delete(may_unwrap(proxy))
	    end
	    super(t)
	end

	def add_permanent_event(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?
	    if proxy = self[t, false]
		auto_tasks.delete(may_unwrap(proxy))
	    end
	    super(t)
	end

	def add(objects)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?
	    super(objects)
	    self
	end

	def unmark_permanent(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?
            t = t.as_plan
	    if proxy = self[t, false]
		super(proxy)
	    end

	    t = may_unwrap(t)
	    if t.plan == self.plan
		auto_tasks.add(t)
	    end
	end

	def unmark_mission(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?
            t = t.as_plan
	    if proxy = self[t, false]
		super(proxy)
	    end

	    t = may_unwrap(t)
	    if t.plan == self.plan
		discarded_tasks.add(t)
	    end
	end

        # The set of invalidation reasons registered with {#invalidate}. It is
        # cleared if the transaction is marked as valid again by calling
        # {#invalid=}.
        #
        # @return [Array<String>]
	attribute(:invalidation_reasons) { Array.new }

        # Marks this transaction as either invalid or valid. If it is marked as
        # valid, it clears {#invalidation_reasons}.
	def invalid=(flag)
	    if !flag
		invalidation_reasons.clear
	    end
	    @invalid = flag
	end

        # True if {#invalidate} has been called, and {#invalid=} has not been
        # called to clear the invalidation afterwards.
	def invalid?; @invalid end

        # Tests if it is safe to commit this transaction
        #
        # @return [Boolean] it returns false if there are other transactions on
        #   top of it. They must be committed or discarded before this transaction
        #   can be committed or discarded. It also returns safe if if this
        #   transaction has been marked as invalid with {#invalidate}
	def valid_transaction?; transactions.empty? && !invalid? end

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
		raise InvalidTransaction, "there is still transactions on top of this one"
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
        def compute_graph_modifications_for(proxy, new_relations, removed_relations, updated_relations)
            real_object = proxy.__getobj__
            proxy.partition_new_old_relations(:each_parent_object, include_proxies: false) do |trsc_objects, rel, new, del, existing|
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
                    updated_relations << [plan_graph, task, real_object, edge_info]
                end
	    end

            proxy.partition_new_old_relations(:each_child_object) do |trsc_objects, rel, new, del, existing|
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
                    updated_relations << [plan_graph, real_object, task, edge_info]
                end
	    end
        end

        # Apply the modifications represented by self to the underlying plan
        # snippet in your redefinition if you do so.
        def apply_modifications_to_plan
            new_missions    = Set.new
            new_permanent  = Set.new

            added_relations   = Array.new
            removed_relations = Array.new
            updated_relations = Array.new

            # We're doing a lot of modifications of this plan .. store some of
            # the sets we need for later, one part to keep them unchanged, one
            # part to make sure we don't do modify-while-iterate
            proxy_objects   = self.proxy_objects.dup
            plan_services   = self.plan_services.dup
            auto_tasks      = self.auto_tasks.dup
            discarded_tasks = self.discarded_tasks.dup
            # We're taking care of the proxies first, so that we can merge the
            # transaction using Plan#merge!. However, this means that
            # #may_unwrap does not work after the first few steps. We therefore
            # have to store the object-to-proxy mapping
            real_objects  = Hash.new

            # We make a copy of all relation graphs, and update them with the
            # transaction data. The underlying plan graphs are not modified
            #
            # We do not #dup them because we don't want to dup the edge info.
            # Instead, we instanciate anew and merge. The add_vertex calls are
            # needed to make sure that the graph dups the in/out sets instead
            # of just copying them
            task_work_graphs, event_work_graphs =
                plan.class.instanciate_relation_graphs
            work_graphs, transaction_graphs = Hash.new, Hash.new
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
            proxy_objects.each do |object, proxy|
                real_objects[proxy] = object
                compute_graph_modifications_for(
                    proxy, added_relations, removed_relations, updated_relations)

                proxy.commit_transaction
                if proxy.self_owned?
                    if proxy.respond_to?(:to_task) && mission?(proxy)
                        new_missions << object
                    elsif permanent?(proxy)
                        new_permanent << object
                    end
                end
            end
            proxy_objects.each_value do |proxy|
                if proxy.root_object?
                    remove_object(proxy)
                end
            end

            work_graphs.each do |plan_g, work_g|
                work_g.merge(transaction_graphs[plan_g])
            end
            apply_graph_modifications(work_graphs, added_relations, removed_relations, updated_relations)

            begin
                validate_graphs(work_graphs.values)
            rescue Exception => e
                raise e, "cannot apply #{self}: #{e.message}", e.backtrace
            end

            #### UNTIL THIS POINT we have not modified the underlying plan AT ALL
            # We DID update the transaction, though

            # Apply #commit_transaction on the remaining tasks
            known_tasks.each(&:commit_transaction)
            free_events.each(&:commit_transaction)

            # What is left in the transaction is the network of new tasks. Just
            # merge it
            plan.merge_transaction!(self, work_graphs,
                                   added_relations, removed_relations, updated_relations)

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
                        if original.task != task
                            plan.move_plan_service(original, task)
                        end
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

            new_missions.each  { |t| plan.add_mission(t) }
            new_permanent.each { |t| plan.add_permanent(t) }

            active_fault_response_tables.each do |tbl|
                plan.use_fault_response_table tbl.model, tbl.arguments
            end

            auto_tasks.each      { |t| plan.unmark_permanent(t) }
            discarded_tasks.each { |t| plan.unmark_mission(t) }

            proxy_objects.each do |object, proxy|
                forwarder_module = Transaction::Proxying.forwarder_module_for(object.model)
                proxy.extend forwarder_module
                proxy.__getobj__ = object
                proxy.__freeze__
            end
        end

	# Commit all modifications that have been registered
	# in this transaction
	def commit_transaction
	    check_valid_transaction
            apply_modifications_to_plan
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

	def enable_proxying; @disable_proxying = false end
	def disable_proxying
	    @disable_proxying = true
	    if block_given?
		begin
		    yield
		ensure
		    @disable_proxying = false
		end
	    end
	end
	def proxying?; !@frozen && !@disable_proxying end

        # Discards this transaction and all the transactions it is part of
        #
        # @return [void]
        def discard_transaction!
            transactions.each do |trsc|
                trsc.discard_transaction!
            end
            discard_transaction
        end

	# Discard all the modifications that have been registered 
	# in this transaction
        #
        # @return [void]
	def discard_transaction
	    if !transactions.empty?
		raise InvalidTransaction, "there is still transactions on top of this one"
	    end

	    frozen!
	    clear

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
            auto_tasks.clear
	    discarded_tasks.clear
	    proxy_objects.each_value { |proxy| proxy.clear_relations }
	    proxy_objects.clear
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
        # @param [EventGenerator] event the finalized event represented by its proxy in self
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
        # DecisionControl#adding_plan_relation(self, parent, child, relations, info) for further action
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
		invalidate("plan added a relation #{parent} -> #{child} in #{relations} with info #{info}")
		control.adding_plan_relation(self, parent, child, relations, info)
	    end
	end

        # Hook called when a relation is removed between plan objects that are
        # present in the transaction
        #
        # If the removed relation is still present in the transaction as well, it
        # invalidates the transaction and calls 
        # DecisionControl#removing_plan_relation(self, parent, child, relations, info) for further action
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
		invalidate("plan removed a relation #{parent} -> #{child} in #{relations}")
		control.removing_plan_relation(self, parent, child, relations)
	    end
	end

	# Returns [plan_set, transaction_set], where the first is the set of
	# plan tasks matching +matcher+ and the second the set of transaction
	# tasks matching it. The two sets are disjoint.
        #
        # This will be stored by the Query object as the query result. Note
        # that, at this point, the transaction has not been modified even though
        # it applies on the global scope. New proxies will only be created when
        # Query#each is called.
	def query_result_set(matcher) # :nodoc:
	    plan_set = Set.new
            if matcher.scope == :global
                plan_result_set = plan.query_result_set(matcher)
                plan.query_each(plan_result_set) do |task|
                    plan_set << task unless self[task, false]
                end
            end
	    
	    transaction_set = super
	    [plan_set, transaction_set]
	end

	# Yields tasks in the result set of +query+. Unlike Query#result_set,
	# all the tasks are included in the transaction
        #
        # +result_set+ is the value returned by #query_result_set.
	def query_each(result_set) # :nodoc:
	    plan_set, trsc_set = result_set
	    plan_set.each { |task| yield(self[task]) }
	    trsc_set.each { |task| yield(task) }
	end

        class ReachabilityVisitor < RGL::DFSVisitor
            attr_reader :transaction
            attr_reader :start_vertex

            def initialize(graph, transaction)
                super(graph)
                @transaction = transaction
            end

            def handle_start_vertex(v)
                @start_vertex = v
            end
        end

        class ReachabilityPlanVisitor < ReachabilityVisitor
            attr_reader :transaction_seeds
            attr_reader :plan_set

            def initialize(graph, transaction, transaction_seeds, plan_set)
                super(graph, transaction)
                @transaction_seeds = transaction_seeds
                @plan_set = plan_set
            end

            def follow_edge?(u, v)
                if transaction.wrap(u, false) && transaction.wrap(v, false)
                    false
                else true
                end
            end

            def handle_examine_vertex(v)
                if (start_vertex != v) && plan_set.include?(v)
                    throw :reachable, true
                elsif proxy = transaction.wrap(v, false)
                    transaction_seeds << proxy
                end
            end
        end

        class ReachabilityTransactionVisitor < ReachabilityVisitor
            attr_reader :transaction_set
            attr_reader :plan_seeds

            def initialize(graph, transaction, plan_seeds, transaction_set)
                super(graph, transaction)
                @plan_seeds = plan_seeds
                @transaction_set = transaction_set
            end

            def handle_examine_vertex(v)
                if (start_vertex != v) && transaction_set.include?(v)
                    throw :reachable, true
                elsif v.transaction_proxy?
                    plan_seeds << v.__getobj__
                end
            end
        end

        # @api private
        #
        # Tests whether a task in plan_set or proxy_set would be reachable from
        # 'task' if the transaction was applied
        def reachable_on_applied_transaction?(transaction_seeds, transaction_set, transaction_graph,
                                              plan_seeds, plan_set, plan_graph)
            transaction_visitor = ReachabilityTransactionVisitor.new(
                transaction_graph, self, plan_seeds, transaction_set)
            if task = transaction_seeds.first
                transaction_visitor.handle_start_vertex(task)
            end
            plan_visitor        = ReachabilityPlanVisitor.new(
                plan_graph, self, transaction_seeds, plan_set)
            if task = plan_seeds.first
                plan_visitor.handle_start_vertex(task)
            end

            catch(:reachable) do
                while !transaction_seeds.empty? || !plan_seeds.empty?
                    transaction_seeds.each do |seed|
                        seed = transaction_seeds.shift
                        if !transaction_visitor.finished_vertex?(seed)
                            transaction_graph.depth_first_visit(seed, transaction_visitor) {}
                        end
                    end
                    transaction_seeds.clear

                    plan_seeds.each do |seed|
                        seed = plan_seeds.shift
                        if !plan_visitor.finished_vertex?(seed)
                            plan_graph.depth_first_visit(seed, plan_visitor) {}
                        end
                    end
                    plan_seeds.clear
                end
                false
            end
        end

        # @api private
        #
	# Given the result set of +query+, returns the subset of tasks which
	# have no parent in +query+
        #
        # This is never called directly, but is used by the Query API
	def query_roots(result_set, relation) # :nodoc:
	    plan_set      , trsc_set      = *result_set
	    plan_children , trsc_children = Set.new     , Set.new

            trsc_graph = task_relation_graph_for(relation).reverse
            plan_graph = plan.task_relation_graph_for(relation).reverse

            plan_result = plan_set.find_all do |task|
                !reachable_on_applied_transaction?(
                    [], trsc_set, trsc_graph,
                    [task], plan_set, plan_graph)
	    end

            trsc_result = trsc_set.find_all do |task|
                !reachable_on_applied_transaction?(
                    [task], trsc_set, trsc_graph,
                    [], plan_set, plan_graph)
	    end

            [plan_result.to_set, trsc_result.to_set]
	end
    end
end

