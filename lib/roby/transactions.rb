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

	def remove_object(object)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if freezed?

	    object = may_unwrap(object)
	    if object.plan == self.plan
		removed_objects.insert(object)
	    end
	    if proxy = self[object, false]
		proxy_objects.delete(proxy.__getobj__) if proxy.respond_to?(:__getobj__)
		super(proxy)
	    end
	end

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
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if freezed?
	    discovered_objects << object
	    super if defined? super
	end
	def discovered_relations_of?(object, relation = nil, written = false)
	    if object.plan != self
		if proxy = wrap(object, false)
		    discovered_relations_of?(proxy, relation, written)
		end
	    elsif !object.kind_of?(Roby::Transactions::Proxy)
		true
	    elsif !discovered_objects.include?(object)
		false
	    else
		object.discovered?(relation, written)
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

	attr_accessor :conflict_solver

	attr_reader :options

	PLAN_UPDATE_MODES = [:invalidate, :update, :solver]

	# What to do if we the plan objects which are modifying are changed
	# inside the plan. Can be either :invalidate, :update or :solver. In
	# the latter case, the object returned by #conflict_solver is called
	# with either #add_plan_relation or #remove_plan_relation
	def on_plan_update; options[:on_plan_update] end

	def on_plan_update=(value)
	    if !PLAN_UPDATE_MODES.include?(value)
		raise ArgumentError, "invalid plan update mode #{value}. Known modes are #{PLAN_UPDATE_MODES.join(", ")}"
	    end
	    if value == :solver && !conflict_solver
		raise ArgumentError, "no conflict solver defined"
	    end
	    options[:on_plan_update] = value
	end

	# Creates a new transaction which applies on +plan+
	def initialize(plan, options = {})
	    @options = validate_options options, 
		:on_plan_update => :invalidate

	    super(plan.hierarchy, plan.service_relations)

	    @plan = plan

	    @proxy_objects      = Hash.new
	    @discovered_objects = ValueSet.new
	    @removed_objects    = ValueSet.new
	    @discarded_tasks    = ValueSet.new
	    @auto_tasks	        = ValueSet.new

	    plan.transactions << self
	    plan.added_transaction(self)
	end

	def include?(t)
	    proxy	= self[t, false]
	    real_task	= may_unwrap(t)
	    (super(proxy) if proxy) ||
		((plan.include?(real_task) && !removed_objects.include?(real_task)) if real_task)
	end
	def mission?(t)
	    real_task = may_unwrap(t)
	    (missions.include?(real_task) && !discarded_tasks.include?(real_task)) || 
		missions.include?(self[t, false])
	end
	def permanent?(t)
	    real_task = may_unwrap(t)
	    (keepalive.include?(real_task) && !auto_tasks.include?(real_task)) || 
		keepalive.include?(self[t, false])
	end

	def missions(own = false)
	    if own then super()
	    else
		plan_missions = plan.missions.
		    difference(discarded_tasks).
		    difference(removed_objects)

		super().union(plan_missions.map(&method(:[])))
	    end
	end

	def known_tasks(own = false)
	    if own then super()
	    else
		plan_tasks = plan.known_tasks. 
		    difference(removed_objects)

		super().union(plan_tasks.map(&method(:[])))
	    end
	end

	def keepalive(own = false)
	    if own then super()
	    else
		plan_tasks = plan.keepalive.
		    difference(auto_tasks)
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

	def insert(t); super(self[t, true]) end
	def permanent(t); super(self[t, true]) end
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

	def discover(objects = nil)
	    raise "transaction #{self} has been either committed or discarded. No modification allowed" if freezed?
	    if !objects then super
	    else super(self[objects, true])
	    end
	    self
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

	    freezed!
	    auto_tasks.each      { |t| plan.auto(t) }
	    discarded_tasks.each { |t| plan.discard(t) }
	    removed_objects.each { |obj| plan.remove_object(obj) }

	    discover  = ValueSet.new
	    insert    = ValueSet.new
	    permanent = ValueSet.new
	    @known_tasks.dup.each do |t|
		unless t.kind_of?(Transactions::Proxy)
		    @known_tasks.delete(t)
		    t.plan = plan
		end

		unwrapped = may_unwrap(t)
		raise if unwrapped.kind_of?(Transactions::Proxy)
		if @missions.include?(t)
		    @missions.delete(t)
		    insert << unwrapped
		elsif @keepalive.include?(t)
		    @keepalive.delete(t)
		    permanent << unwrapped
		else
		    discover << unwrapped
		end
	    end
	    @free_events.dup.each do |ev|
		unless ev.kind_of?(Transactions::Proxy)
		    @free_events.delete(ev)
		    ev.plan = plan
		end
		discover << may_unwrap(ev)
	    end

	    # Set the plan to nil in known tasks to avoid having the checks on
	    # #plan to raise an exception
	    discovered_objects.each { |proxy| proxy.commit_transaction }
	    proxy_objects.each { |_, proxy| proxy; proxy.clear_relations  }

	    plan.discover(discover)
	    insert.each { |t| plan.insert(t) }
	    permanent.each { |t| plan.permanent(t) }

	    proxies     = proxy_objects.dup
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

	def enable_proxying; @disable_proxying = false end
	def disable_proxying; @disable_proxying = true end
	def proxying?; !@freezed && !@disable_proxying end

	# Discard all the modifications that have been registered 
	# in this transaction
	def discard_transaction
	    unless transactions.empty?
		raise InvalidTransaction, "there is still transactions on top of this one"
	    end

	    freezed!
	    proxy_objects.each { |_, proxy| proxy.discard_transaction }
	    clear

	    discarded_transaction
	    plan.transactions.delete(self)
	    plan.removed_transaction(self)
	end
	def discarded_transaction; super if defined? super end

	def freezed!
	    @freezed = true
	end

	def clear
	    discovered_objects.clear
	    removed_objects.clear
	    discarded_tasks.clear
	    proxy_objects.each do |_, proxy|
		proxy.clear_relations
	    end
	    proxy_objects.clear
	    super
	end
    end
end

require 'roby/transactions/updates'

