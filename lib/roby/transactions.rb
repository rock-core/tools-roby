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

        def create_proxy(proxy, object, klass = nil)
            proxy ||= object.dup
            klass ||= object.class
            proxy.extend Roby::Transaction::Proxying.proxying_module_for(klass)
            proxy.setup_proxy(object, self)
            proxy
        end

        def register_proxy(proxy, object, do_include = false)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?

            proxy = create_proxy(proxy, object)
            proxy_objects[object] = proxy

	    if do_include && object.root_object?
		proxy.plan = self
		add(proxy)
	    end
	    copy_object_relations(object, proxy)

            if services = plan.plan_services[object]
                services.each do |original_srv|
                    srv = create_proxy(nil, original_srv)
                    srv.task = proxy
                    add_plan_service(srv)
                end
            end

	    proxy
        end

	def do_wrap(object, do_include = false) # :nodoc:
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?

	    if proxy = proxy_objects[object]
                return proxy
            elsif !object.root_object?
                do_wrap(object.root_object, do_include)
                if !(proxy = proxy_objects[object])
                    raise InternalError, "#{object} should have been wrapped but is not"
                end
                register_proxy(proxy, object, do_include)
            else
                register_proxy(object.dup, object, do_include)
            end
	end

	def propose; end
	def edit
	    yield if block_given?
	end

	# This method copies on +proxy+ all relations of +object+ for which
	# both ends of the relation are already in the transaction.
	def copy_object_relations(object, proxy)
	    Roby.synchronize do
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
	end

	# Get the transaction proxy for +object+
	def wrap(object, create = true)
	    if object.kind_of?(PlanObject)
		if object.plan == self then return object
		elsif proxy = proxy_objects[object] then return proxy
		end

                if !object.plan
                    object.plan = self
                    add(object)
                    return object
                end

		if create
		    if object.plan != self.plan
			raise ArgumentError, "#{object} is in #{object.plan}, this transaction #{self} applies on #{self.plan}"
                    end

                    wrapped = do_wrap(object, true)
                    if object.respond_to?(:to_task) && plan.mission?(object)
                        add_mission(wrapped)
                    elsif plan.permanent?(object)
                        add_permanent(wrapped)
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

	    Roby.synchronize do
		proxy_children = proxy.child_objects(relation)
		object.child_objects(relation).each do |object_child| 
		    next unless proxy_child = wrap(object_child, false)
		    if proxy_children.include?(proxy_child)
			relation.unlink(proxy, proxy_child)
		    end
		end

		proxy_parents = proxy.parent_objects(relation)
		object.parent_objects(relation).each do |object_parent| 
		    next unless proxy_parent = wrap(object_parent, false)
		    if proxy_parents.include?(proxy_parent)
			relation.unlink(parent, proxy_parent)
		    end
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
            if (proxy || object).plan != self
                raise InternalError, "inconsistency"
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
	    @discarded_tasks    = ValueSet.new
	    @auto_tasks	        = ValueSet.new

	    Roby.synchronize do
		plan.transactions << self
		plan.added_transaction(self)
	    end
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

	def add_mission(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?
            t = t.as_plan
	    if proxy = self[t, false]
		discarded_tasks.delete(may_unwrap(proxy))
	    end
	    super(t)
	end

	def add_permanent(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if frozen?
            t = t.as_plan
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
		auto_tasks.insert(t)
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
		discarded_tasks.insert(t)
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

	# Commit all modifications that have been registered
	# in this transaction
	def commit_transaction
	    # if !Roby.control.running?
	    #     raise "#commit_transaction requires the presence of a control thread"
	    # end

	    check_valid_transaction
	    frozen!

	    plan.execute do
		auto_tasks.each      { |t| plan.unmark_permanent(t) }
		discarded_tasks.each { |t| plan.unmark_mission(t) }

		discover_tasks  = ValueSet.new
		discover_events  = ValueSet.new
		insert    = ValueSet.new
		permanent = ValueSet.new
		known_tasks.dup.each do |t|
		    unwrapped = if t.kind_of?(Transaction::Proxying)
				    finalized_task(t)
				    t.__getobj__
				else
				    known_tasks.delete(t)
				    t
				end

		    if missions.include?(t) && t.self_owned?
			missions.delete(t)
			insert << unwrapped
		    elsif permanent_tasks.include?(t) && t.self_owned?
			permanent_tasks.delete(t)
			permanent << unwrapped
		    end

		    discover_tasks << unwrapped
		end

		free_events.dup.each do |ev|
		    unwrapped = if ev.kind_of?(Transaction::Proxying)
				    finalized_event(ev)
				    ev.__getobj__
				else
				    free_events.delete(ev)
				    ev
				end

                    if permanent_events.include?(ev) && ev.self_owned?
                        permanent_events.delete(ev)
                        permanent << unwrapped
                    end

		    discover_events << unwrapped
		end

		new_tasks = discover_tasks - plan.known_tasks
                new_tasks.each do |t|
                    t.commit_transaction
                end
                plan.add_task_set(new_tasks)
		new_events = discover_events - plan.free_events
                new_events.each do |e|
                    e.commit_transaction
                end
                plan.add_event_set(new_events)

		# Set the plan to nil in known tasks to avoid having the checks on
		# #plan to raise an exception
		proxy_objects.each_value { |proxy| proxy.commit_transaction }
		proxy_objects.each_value { |proxy| proxy.clear_relations  }

                # Update the plan services on the underlying plan. The only
                # thing we need to take care of is replacements and new
                # services. Other modifications will be applied automatically
                plan_services.each do |task, services|
                    services.each do |srv|
                        if srv.transaction_proxy?
                            # Modified service. Might be moved to a new task
                            original = srv.__getobj__
                            task     = may_unwrap(task)
                            if original.task != task
                                plan.move_plan_service(original, task)
                            end
                            srv.commit_transaction
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

		insert.each    { |t| plan.add_mission(t) }
		permanent.each { |t| plan.add_permanent(t) }

		proxies     = proxy_objects.dup
		clear
		# Replace proxies by forwarder objects
		proxies.each do |object, proxy|
		    forwarder_module = Transaction::Proxying.forwarder_module_for(object.model)
                    proxy.extend forwarder_module
                    proxy.__freeze__
		end

                @committed = true
		committed_transaction
		plan.remove_transaction(self)
		@plan = nil

		yield if block_given?
	    end
	end

        # Hook called just after this transaction has been committed
        #
        # @return [void]
	def committed_transaction; super if defined? super end

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
	    proxy_objects.each_value { |proxy| proxy.discard_transaction }
	    clear

	    discarded_transaction
	    plan.execute do
		plan.remove_transaction(self)
	    end
	    @plan = nil
	end

        # Hook called just after this transaction has been discarded
        #
        # @return [void]
	def discarded_transaction; super if defined? super end

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
        # @param [Array<RelationGraph>] relations the graphs in which a relation
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
        # @param [Array<RelationGraph>] relations the graphs in which a relation
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

	# Returns two sets of tasks, [plan, transaction]. The union of the two
	# is the component that would be returned by
	# +relation.generated_subgraphs(*seeds)+ if the transaction was
	# committed
        #
        # This is an internal method used by queries
	def merged_generated_subgraphs(relation, plan_seeds, transaction_seeds)
	    plan_set        = ValueSet.new
	    transaction_set = ValueSet.new
	    plan_seeds	      = plan_seeds.to_value_set
	    transaction_seeds = transaction_seeds.to_value_set

	    loop do
		old_transaction_set = transaction_set.dup
		transaction_set.merge(transaction_seeds)
		for new_set in relation.generated_subgraphs(transaction_seeds, false)
		    transaction_set.merge(new_set)
		end

		if old_transaction_set.size != transaction_set.size
		    for o in (transaction_set - old_transaction_set)
			if o.respond_to?(:__getobj__)
			    o.__getobj__.each_child_object(relation) do |child|
				plan_seeds << child unless self[child, false]
			    end
			end
		    end
		end
		transaction_seeds.clear

		plan_set.merge(plan_seeds)
		plan_seeds.each do |seed|
		    relation.each_dfs(seed, BGL::Graph::TREE) do |_, dest, _, kind|
			next if plan_set.include?(dest)
			if self[dest, false]
			    proxy = wrap(dest, false)
			    unless transaction_set.include?(proxy)
				transaction_seeds << proxy
			    end
			    relation.prune # transaction branches must be developed inside the transaction
			else
			    plan_set << dest
			end
		    end
		end
		break if transaction_seeds.empty?

		plan_seeds.clear
	    end

	    [plan_set, transaction_set]
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
	    plan_set = ValueSet.new
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

	# Given the result set of +query+, returns the subset of tasks which
	# have no parent in +query+
	def query_roots(result_set, relation) # :nodoc:
	    plan_set      , trsc_set      = *result_set
	    plan_result   , trsc_result   = ValueSet.new     , ValueSet.new
	    plan_children , trsc_children = ValueSet.new     , ValueSet.new

	    for task in plan_set
		next if plan_children.include?(task)
		task_plan_children, task_trsc_children = 
		    merged_generated_subgraphs(relation, [task], [])

		plan_result -= task_plan_children
		trsc_result -= task_trsc_children
		plan_children.merge(task_plan_children)
		trsc_children.merge(task_trsc_children)

		plan_result << task
	    end

	    for task in trsc_set
		next if trsc_children.include?(task)
		task_plan_children, task_trsc_children = 
		    merged_generated_subgraphs(relation, [], [task])

		plan_result -= task_plan_children
		trsc_result -= task_trsc_children
		plan_children.merge(task_plan_children)
		trsc_children.merge(task_trsc_children)

		trsc_result << task
	    end

	    [plan_result, trsc_result]
	end
    end
end

