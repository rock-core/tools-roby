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
	    when Roby::PlanObject
		discover(object) if object.root_object?
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

	def may_wrap(object, create = true); (wrap(object, create) || object) rescue object end
	
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
	    @discovered_objects = ValueSet.new
	    @removed_objects    = ValueSet.new
	    @discarded_tasks    = ValueSet.new
	    @auto_tasks	        = ValueSet.new

	    plan.transactions << self
	    plan.added_transaction(self)
	end

	def replace(from, to)
	    super(wrap(from, true), wrap(to, true))
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
		if t.kind_of?(Transactions::Proxy)
		    unwrapped = t.__getobj__
		else
		    @known_tasks.delete(t)
		    t.plan = plan
		    unwrapped = t
		end

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
		if ev.kind_of?(Transactions::Proxy)
		    unwrapped = ev.__getobj__
		else
		    @free_events.delete(ev)
		    ev.plan = plan
		    unwrapped = ev
		end
		discover << unwrapped
	    end

	    # Set the plan to nil in known tasks to avoid having the checks on
	    # #plan to raise an exception
	    discovered_objects.each { |proxy| proxy.commit_transaction }
	    proxy_objects.each_value { |proxy| proxy.clear_relations  }

	    plan.discover(discover)
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
	end
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
	end
	def discarded_transaction; super if defined? super end

	def freezed!
	    @freezed = true
	end

	def clear
	    discovered_objects.clear
	    removed_objects.clear
	    discarded_tasks.clear
	    proxy_objects.each_value { |proxy| proxy.clear_relations }
	    proxy_objects.clear
	    super
	end
    end
end

require 'roby/transactions/updates'

