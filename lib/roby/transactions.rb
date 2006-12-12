require 'roby/plan'
require 'utilrb/value_set'
require 'utilrb/kernel/swap'
require 'roby/transactions/proxy'

module Roby
    # A transaction is a special kind of plan. It allows to build plans in a separate
    # sandbox, and then to apply the modifications to the real plan (using #commit_transaction), or
    # to discard all modifications (using #discard)
    class Transaction < Plan
	Proxy = Transactions::Proxy
	
	# A transaction is not an executable plan
	def executable?; false end

	def do_wrap(object, do_include = false) # :nodoc:
	    object = proxy_objects[object] = Proxy.proxy_class(object).new(object, self)
	    object.plan = self
	    do_include(object) if do_include
	    object
	end
	def do_include(object)
	    case object
	    when Roby::Transactions::Task
		@known_tasks << object
		discovered_tasks([object])
	    when Roby::Transactions::TaskEventGenerator
	    when Roby::Transactions::EventGenerator
		@free_events << object
		discovered_events([object])
	    when Roby::PlanObject
		discover(object)
	    else
		raise TypeError, "unknown object type #{object} (#{object.class})"
	    end
	    object
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
			return do_include(object)
		    elsif object.plan == self.plan
			return do_wrap(object, true)
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
		raise TypeError, "don't know how to wrap #{object}"
	    end
	end
	alias :[] :wrap

	def may_wrap(object); wrap(object) rescue object end
	
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

	# The list of objects that have been discovered in this transaction
	# 'discovered' objects are the objects in which relation modifications
	# will be checked on commit
	attr_reader :discovered_objects

	# Called when +relation+ has been discovered on +object+
	def discovered_object(object, relation)
	    discovered_objects << object
	    super if defined? super
	end
	def discovered_relations_of?(object)
	    !object.kind_of?(Roby::Transactions::Proxy) || discovered_objects.include?(object)
	end

	# The list of discarded
	attr_reader :discarded_tasks
	# The list of removed tasks
	attr_reader :removed_tasks
	# The plan this transaction applies on
	attr_reader :plan
	# The proxy objects built for this transaction
	attr_reader :proxy_objects

	# Creates a new transaction which applies on +plan+
	def initialize(plan)
	    super(plan.hierarchy, plan.service_relations)

	    @plan = plan

	    @proxy_objects      = Hash.new
	    @discovered_objects = ValueSet.new
	    @removed_tasks      = ValueSet.new
	    @discarded_tasks    = ValueSet.new

	    plan.transactions << self
	    plan.added_transaction(self)
	end

	def include?(t)
	    proxy	= self[t, false]
	    real_task	= may_unwrap(t)
	    (super(proxy) if proxy) ||
		((plan.include?(real_task) && !removed_tasks.include?(real_task)) if real_task)
	end
	def mission?(t)
	    real_task = may_unwrap(t)
	    (missions.include?(real_task) && !discarded_tasks.include?(real_task)) || 
		missions.include?(self[t, false])
	end

	def missions(own = false)
	    if own then super()
	    else
		plan_missions = plan.missions.
		    difference(discarded_tasks).
		    difference(removed_tasks)

		super().union(plan_missions.map(&method(:[])))
	    end
	end

	def known_tasks(own = false)
	    if own then super()
	    else
		plan_tasks = plan.known_tasks. 
		    difference(removed_tasks)

		super().union(plan_tasks.map(&method(:[])))
	    end
	end
	def empty?(own = false)
	    if own then super()
	    else super() && plan.empty?
	    end
	end
	
	# Iterates on all tasks
	def each_task(own = false); known_tasks(own).each { |t| yield(t) } end

	def insert(t)
	    super(self[t, true])
	end

	def discover(objects = nil)
	    if !objects then super
	    else super(self[objects, true])
	    end

	    # Consistency check
	    unless (@known_tasks & plan.known_tasks).empty? && (@free_events & plan.free_events).empty?
		raise PlanModelViolation, "transactions and plans cannot share tasks. Use proxys"
	    end

	    self
	end

	def discard(t)
	    if proxy = self[t, false]
		super(proxy)
	    end

	    t = may_unwrap(t)
	    if t.plan == self.plan
		discarded_tasks.insert(t)
	    end
	end

	def remove_task(t)
	    if proxy = self[t, false]
		super(proxy)
	    end

	    t = may_unwrap(t)
	    if t.plan == self.plan
		removed_tasks.insert(t)
	    end
	end

	def valid_transaction?
	    transactions.empty?
	end

	# Commit all modifications that have been registered
	# in this transaction
	def commit_transaction
	    unless transactions.empty?
		raise ArgumentError, "there is still transactions on top of this one"
	    end
	    unless valid_transaction?
		raise ArgumentError, "invalid transaction"
	    end

	    discarded_tasks.each { |t| plan.discard(t) }
	    removed_tasks.each { |t| plan.remove_task(t) }

	    raise unless (@missions - @known_tasks).empty?
	    # Set the plan to nil in known tasks to avoid having 
	    # the checks on #plan to raise an exception
	    @missions.each    { |t| t.plan = self.plan unless t.kind_of?(Proxy) }
	    @known_tasks.each { |t| t.plan = self.plan unless t.kind_of?(Proxy) }
	    @free_events.each { |e| e.plan = self.plan unless e.kind_of?(Proxy) }

	    discovered_objects.each { |proxy| proxy.commit_transaction }
	    proxy_objects.each { |_, proxy| proxy.disable_proxying! }
	    proxy_objects.each { |_, proxy| proxy.clear_relations  }

	    # Call #insert and #discover *after* we have cleared relations
	    @missions.delete_if    { |t| plan.insert(t)   unless t.kind_of?(Proxy) }
	    @known_tasks.delete_if { |t| plan.discover(t) unless t.kind_of?(Proxy) }
	    @free_events.delete_if { |e| plan.discover(e) unless e.kind_of?(Proxy) }

	    proxies = proxy_objects.dup
	    clear
	    # Replace proxies by forwarder objects
	    proxies.each do |object, proxy|
		Kernel.swap! proxy, Proxy.forwarder(object)
	    end

	    committed_transaction
	    plan.transactions.delete(self)
	    plan.removed_transaction(self)
	end
	def committed_transaction; super if defined? super end

	# Discard all the modifications that have been registered 
	# in this transaction
	def discard_transaction
	    unless transactions.empty?
		raise ArgumentError, "there is still transactions on top of this one"
	    end

	    # Clear proxies
	    proxy_objects.each { |_, proxy| proxy.discard_transaction }

	    # Clear the underlying plan
	    clear

	    discarded_transaction
	    plan.transactions.delete(self)
	    plan.removed_transaction(self)
	end
	def discarded_transaction; super if defined? super end

	def clear
	    discovered_objects.clear
	    removed_tasks.clear
	    discarded_tasks.clear
	    proxy_objects.each do |_, proxy|
		proxy.clear_relations
	    end
	    proxy_objects.clear
	    super
	end
    end
end

