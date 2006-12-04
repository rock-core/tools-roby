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

	# Get the transaction proxy for +object+
	def wrap(object)
	    if object.kind_of?(PlanObject)
		if object.plan == self
		    return object
		elsif !object.plan
		    object.plan = self
		    return object
		elsif object.kind_of?(Proxy)
		    raise ArgumentError, "#{object} is in #{object.plan}, not from this transaction (#{self})"
		elsif proxy = proxy_objects[object]
		    return proxy
		else
		    object = proxy_objects[object] = Proxy.proxy_class(object).new(object, self)
		    object
		end
	    elsif object.respond_to?(:each) 
		object.map(&method(:wrap))
	    elsif object.respond_to?(:each_event)
		object.enum_for(:each_event).map(&method(:wrap))
	    elsif object.respond_to?(:each_task)
		object.enum_for(:each_task).map(&method(:wrap))
	    else
		raise TypeError, "don't know how to wrap #{object}"
	    end
	end
	def may_wrap(object); wrap(object) rescue object end
	alias :[] :wrap

	# The list of objects that have been discovered in this transaction
	# 'discovered' objects are the objects in which relation modifications
	# will be checked on commit
	attr_reader :discovered_objects

	# Announce that +object+ has been discovered
	def discovered_object(object)
	    discovered_objects << object
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
	    real_task = Proxy.may_unwrap(t)
	    (plan.include?(real_task) && !removed_tasks.include?(real_task)) || 
		super(self[t]) 
	end
	def mission?(t)
	    real_task = Proxy.may_unwrap(t)
	    (missions.include?(real_task) && !discarded_tasks.include?(real_task)) || 
		missions.include?(self[t])
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
	    super(self[t])
	end

	def discover(objects = nil)
	    if !objects then super
	    else super(self[objects])
	    end

	    # Consistency check
	    unless (@known_tasks & plan.known_tasks).empty? && (@free_events & plan.free_events).empty?
		raise PlanModelViolation, "transactions and plans cannot share tasks. Use proxys"
	    end

	    self
	end

	def discard(t)
	    unwrapped = Proxy.may_unwrap(t)
	    if plan.missions.include?(unwrapped)
		discarded_tasks.insert(unwrapped)
	    else
		super
	    end
	end

	def remove_task(t)
	    unwrapped = Proxy.may_unwrap(t)
	    if plan.known_tasks.include? unwrapped
		removed_tasks.insert(unwrapped)
	    else
		super
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

	    proxy_objects.each { |_, proxy| proxy.disable_discovery! }
	    proxy_objects.each { |_, proxy| proxy.clear_vertex }

	    # Call #insert and #discover *after* we have cleared relations
	    @missions.each    { |t| plan.insert(t)   unless t.kind_of?(Proxy) }
	    @known_tasks.each { |t| plan.discover(t) unless t.kind_of?(Proxy) }
	    @free_events.each { |e| plan.discover(e) unless e.kind_of?(Proxy) }

	    # Replace proxies by forwarder objects
	    proxy_objects.each do |object, proxy|
		raise if plan.known_tasks.include?(proxy)
		Kernel.swap! proxy, Proxy.forwarder(proxy).new(object)
	    end

	    plan.transactions.delete(self)
	    committed_transaction
	end
	def committed_transaction; super if defined? super end

	# Discard all the modifications that have been registered 
	# in this transaction
	def discard_transaction
	    unless transactions.empty?
		raise ArgumentError, "there is still transactions on top of this one"
	    end

	    # Clear the underlying plan
	    clear

	    # Clear all remaining proxies
	    proxy_objects.each { |_, proxy| proxy.discard_transaction }
	    proxy_objects.clear
	    discovered_objects.clear
	    removed_tasks.clear
	    discarded_tasks.clear

	    plan.transactions.delete(self)
	    discarded_transaction
	end
	def discarded_transaction; super if defined? super end
    end
end

