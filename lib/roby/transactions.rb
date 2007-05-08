require 'roby/plan'
require 'utilrb/value_set'
require 'utilrb/kernel/swap'
require 'roby/transactions/proxy'

module Roby
    # Exception raised when someone tries do commit an invalid transaction
    class InvalidTransaction < RuntimeError; end

    # A transaction is a special kind of plan. It allows to build plans in a separate
    # sandbox, and then to apply the modifications to the real plan (using #commit_transaction), or
    # to discard all modifications (using #discard)
    class Transaction < Plan
	Proxy = Transactions::Proxy
	
	# A transaction is not an executable plan
	def executable?; false end
	def freezed?; @freezed end

	def do_wrap(object, do_include = false) # :nodoc:
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if freezed?

	    proxy = proxy_objects[object] = Proxy.proxy_class(object).new(object, self)
	    if do_include && object.root_object?
		proxy.plan = self
		discover(proxy)
	    end

	    copy_object_relations(object, proxy)
	    proxy
	end

	# This method copies on +proxy+ all relations of +object+ for which
	# both ends of the relation are already in the transaction.
	def copy_object_relations(object, proxy)
	    Roby::Control.synchronize do
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

		if create
		    if !object.plan
			object.plan = self
			discover(object)
			return object
		    elsif object.plan == self.plan
			wrapped = do_wrap(object, true)
			if plan.mission?(object)
			    insert(wrapped)
			elsif plan.permanent?(object)
			    permanent(wrapped)
			end
			return wrapped
		    else
			raise ArgumentError, "#{object} is in #{object.plan}, this transaction #{self} applies on #{self.plan}"
		    end
		end
		nil
	    elsif object.respond_to?(:each) 
		object.map { |o| wrap(o, create) }
	    elsif object.respond_to?(:each_event)
		object.enum_for(:each_event) { |o| wrap(o, create) }
	    elsif object.respond_to?(:each_task)
		object.enum_for(:each_task) { |o| wrap(o, create) }
	    else
		raise TypeError, "don't know how to wrap #{object || 'nil'}"
	    end
	end
	alias :[] :wrap

	# Remove +proxy+ from this transaction. While #remove_object is also
	# removing the object from the plan itself, this method only removes it
	# from the transaction, forgetting all modifications that have been
	# done on +object+ in the transaction
	def discard_modifications(object)
	    object = may_unwrap(object)
	    if object.respond_to?(:each_plan_child)
		object.each_plan_child do |child|
		    discard_modifications(child)
		end
	    end
	    removed_objects.delete(object)
	    discarded_tasks.delete(object)
	    auto_tasks.delete(object)

	    return unless proxy = proxy_objects.delete(object)
	    proxy.clear_vertex

	    missions.delete(proxy)
	    known_tasks.delete(proxy)
	    free_events.delete(proxy)
	end

	def restore_relation(proxy, relation)
	    object = proxy.__getobj__

	    Control.synchronize do
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

	    discovered_objects.delete(proxy)
	    proxy.discovered_relations.delete(relation)
	    proxy.do_discover(relation, false)
	end

	alias :remove_plan_object :remove_object
	def remove_object(object)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if freezed?

	    object = may_unwrap(object)
	    proxy = proxy_objects[object] || object

	    # removing the proxy may trigger some discovery (event relations
	    # for instance, if proxy is a task). Do it first, or #discover
	    # will be called and the modifications of internal structures
	    # nulled (like #removed_objects) ...
	    remove_plan_object(proxy)
	    proxy_objects.delete(object)

	    if object.plan == self.plan
		# +object+ is new in the transaction
		removed_objects.insert(object)
	    end
	end

	def may_wrap(object, create = true)
	    (wrap(object, create) || object) rescue object 
	end
	
	# may_unwrap may return objects from transaction
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
	# The list of removed tasks and events
	attr_reader :removed_objects
	# The list of permanent tasks that have been auto'ed
	attr_reader :auto_tasks
	# The plan this transaction applies on
	attr_reader :plan
	# The proxy objects built for this transaction
	attr_reader :proxy_objects

	attr_reader :conflict_solver
	attr_reader :options

	def conflict_solver=(value)
	    @conflict_solver = case value
			       when :update
				   SolverUpdateRelations
			       when :invalidate
				   SolverInvalidateTransaction
			       when :ignore
				   SolverIgnoreUpdate.new
			       else value
			       end
	end

	# Creates a new transaction which applies on +plan+
	def initialize(plan, options = {})
	    options = validate_options options, 
		:conflict_solver => :invalidate

	    @options = options
	    self.conflict_solver = options[:conflict_solver]
	    super(plan.hierarchy, plan.service_relations)

	    @plan = plan

	    @proxy_objects      = Hash.new
	    @removed_objects    = ValueSet.new
	    @discarded_tasks    = ValueSet.new
	    @auto_tasks	        = ValueSet.new

	    Roby::Control.synchronize do
		plan.transactions << self
		plan.added_transaction(self)
	    end
	end

	def discover_neighborhood(object)
	    self[object]
	    object.each_relation do |rel|
		object.each_parent_object(rel) { |obj| self[obj] }
		object.each_child_object(rel)  { |obj| self[obj] }
	    end
	end

	def replace(from, to)
	    # Make sure +from+, its events and all the related tasks and events
	    # are in the transaction
	    from = may_unwrap(from)
	    discover_neighborhood(from)
	    from.each_event do |ev|
		discover_neighborhood(ev)
	    end

	    super(self[from], self[to])
	end

	def insert(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if freezed?
	    if proxy = self[t, false]
		discarded_tasks.delete(may_unwrap(proxy))
	    end
	    super(self[t, true]) 
	end
	def permanent(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if freezed?
	    if proxy = self[t, false]
		auto_tasks.delete(may_unwrap(proxy))
	    end
	    super(self[t, true]) 
	end
	def discover(objects = nil)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if freezed?
	    if !objects then super
	    else super(self[objects, true])
	    end
	    self
	end

	def auto(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if freezed?
	    if proxy = self[t, false]
		super(proxy)
	    end

	    t = may_unwrap(t)
	    if t.plan == self.plan
		auto_tasks.insert(t)
	    end
	end

	def discard(t)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if freezed?
	    if proxy = self[t, false]
		super(proxy)
	    end

	    t = may_unwrap(t)
	    if t.plan == self.plan
		discarded_tasks.insert(t)
	    end
	end

	attribute(:invalidation_reasons) { Array.new }

	def invalid=(flag)
	    if !flag
		invalidation_reasons.clear
	    end
	    @invalid = flag
	end

	def invalid?; @invalid end
	def valid_transaction?; transactions.empty? && !invalid? end
	def invalidate(reason = nil)
	    self.invalid = true
	    invalidation_reasons << [reason, caller(1)] if reason
	    Roby.debug do
		"invalidating #{self}: #{reason}"
	    end
	end
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
	    check_valid_transaction

	    if !Roby.inside_control?
		raise ThreadError, "trying to commit a transaction outside the control thread"
	    end

	    freezed!
	    auto_tasks.each      { |t| plan.auto(t) }
	    discarded_tasks.each { |t| plan.discard(t) }
	    removed_objects.each { |obj| plan.remove_object(obj) }

	    discover_tasks  = ValueSet.new
	    discover_events  = ValueSet.new
	    insert    = ValueSet.new
	    permanent = ValueSet.new
	    known_tasks.dup.each do |t|
		unwrapped = if t.kind_of?(Transactions::Proxy)
				finalized_task(t)
				t.__getobj__
			    else
				known_tasks.delete(t)
				t
			    end

		if missions.include?(t)
		    missions.delete(t)
		    insert << unwrapped
		elsif keepalive.include?(t)
		    keepalive.delete(t)
		    permanent << unwrapped
		end

		discover_tasks << unwrapped
	    end

	    free_events.dup.each do |ev|
		unwrapped = if ev.kind_of?(Transactions::Proxy)
				finalized_event(ev)
				ev.__getobj__
			    else
				free_events.delete(ev)
				ev
			    end

		discover_events << unwrapped
	    end

	    plan.discover_task_set(discover_tasks)
	    plan.discover_event_set(discover_events)

	    # Set the plan to nil in known tasks to avoid having the checks on
	    # #plan to raise an exception
	    proxy_objects.each_value { |proxy| proxy.commit_transaction }
	    proxy_objects.each_value { |proxy| proxy.clear_relations  }

	    insert.each    { |t| plan.insert(t) }
	    permanent.each { |t| plan.permanent(t) }

	    proxies     = proxy_objects.dup
	    clear
	    # Replace proxies by forwarder objects
	    proxies.each do |object, proxy|
		Kernel.swap! proxy, Proxy.forwarder(object)
	    end

	    committed_transaction
	    plan.remove_transaction(self)
	    @plan = nil
	end
	def committed_transaction; super if defined? super end
	def finalized?; !plan end

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
	def proxying?; !@freezed && !@disable_proxying end

	# Discard all the modifications that have been registered 
	# in this transaction
	def discard_transaction
	    unless transactions.empty?
		raise InvalidTransaction, "there is still transactions on top of this one"
	    end

	    freezed!
	    proxy_objects.each_value { |proxy| proxy.discard_transaction }
	    clear

	    discarded_transaction
	    plan.remove_transaction(self)
	    @plan = nil
	end
	def discarded_transaction; super if defined? super end

	def freezed!
	    @freezed = true
	end

	def clear
	    removed_objects.clear
	    discarded_tasks.clear
	    proxy_objects.each_value { |proxy| proxy.clear_relations }
	    proxy_objects.clear
	    super
	end
    end
end

require 'roby/transactions/updates'

