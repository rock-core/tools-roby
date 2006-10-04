require 'roby/transactions/proxy'
require 'utilrb/value_set'
require 'roby/plan'
require 'facet/kernel/as'
require 'utilrb/kernel/swap'

module Roby
    # A transaction is a special kind of plan. It allows to build plans in a separate
    # sandbox, and then to apply the modifications to the real plan (using #commit_transaction), or
    # to discard all modifications (using #discard)
    class Transaction < Plan
	Proxy = Transactions::Proxy

	# Get the transaction proxy for +object+
	def [](object)
	    object = if object.kind_of?(Proxy)
			 object
		     else wrap(object)
		     end

	    if object.kind_of?(Task)
		object.plan = self
	    end

	    object
	end

	def executable?; false end

	def wrap(object)
	    if proxy = proxies[object]
		return proxy
	    end
	    proxies[object] = Proxy.proxy_class(object).new(object, self)
	end
	def may_wrap(object); wrap(object) rescue object end

	def discovered(object)
	    discovered_objects << object
	end
	

	attr_reader :plan, :discarded, :removed, :proxies, :discovered_objects
	def initialize(plan)
	    super(plan.hierarchy, plan.service_relations)

	    @plan = plan

	    @proxies   = Hash.new
	    @discovered_objects = ValueSet.new
	    @removed   = ValueSet.new
	    @discarded = ValueSet.new
	end

	def include?(t); super || super(may_wrap(t)) end
	def mission?(t); super || super(may_wrap(t)) end

	def missions
	    plan_missions = plan.missions.
		difference(discarded).
		difference(removed)

	    super.union(plan_missions.map(&method(:[])))
	end

	def known_tasks
	    plan_tasks = plan.known_tasks. 
		difference(removed)

	    super.union(plan_tasks.map(&method(:[])))
	end


	def insert(t)
	    t = if plan.include?(t) then self[t]
		else Proxy.may_unwrap(t)
		end

	    super(t)
	end

	def discover(tasks = nil)
	    apply(tasks) do |t|
		t = if plan.include?(t) then self[t]
		    else Proxy.may_unwrap(t)
		    end

		super(t)
	    end
	end

	def discard(t)
	    unwrapped = Proxy.may_unwrap(t)
	    if plan.missions.include?(unwrapped)
		discarded.insert(unwrapped)
	    else
		super
	    end
	end

	def remove_task(t)
	    unwrapped = Proxy.may_unwrap(t)
	    if plan.known_tasks.include? unwrapped
		removed.insert(unwrapped)
	    else
		super
	    end
	end

	# Commit all modifications that have been registered
	# in this transaction
	def commit_transaction
	    discarded.each { |t| plan.discard(t) }
	    removed.each { |t| plan.remove_task(t) }

	    # Set the plan to nil in known tasks to avoid having 
	    # the check on #plan to raise an exception
	    @known_tasks.each { |t| t.plan = self.plan }

	    discovered_objects.each { |proxy| proxy.commit_transaction }
	    proxies.each { |_, proxy| proxy.disable_discovery! }
	    proxies.each { |_, proxy| proxy.clear_vertex }

	    # Call #insert and #discover *after* we have cleared relations
	    @missions.each    { |t| plan.insert(t) unless t.kind_of?(Proxy) }
	    @known_tasks.each { |t| plan.discover(t) unless t.kind_of?(Proxy) }

	    proxies.each do |object, proxy|
		# Make sure +proxy+ won't be discovered
		Kernel.swap! proxy, Proxy.forwarder(proxy).new(object)
	    end
	end

	# Discard all the modifications that have been registered 
	# in this transaction
	def discard_transaction
	    # Clear the underlying plan
	    clear

	    # Clear all remaining proxies
	    proxies.each { |_, proxy| proxy.discard_transaction }
	    proxies.clear
	    discovered_objects.clear
	    removed.clear
	    discarded.clear
	end
    end
end

