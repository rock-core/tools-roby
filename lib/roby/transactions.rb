require 'roby/transactions/proxy'
require 'utilrb/value_set'
require 'roby/plan'
require 'facet/kernel/as'

module Roby
    # A transaction is a special kind of plan. It allows to build plans in a separate
    # sandbox, and then to apply the modifications to the real plan (using #commit), or
    # to discard all modifications (using #discard)
    class Transaction < Plan
	Proxy = Transactions::Proxy

	def [](object)
	    if object.class.has_ancestor?(Proxy)
		object
	    else
		Proxy.wrap(object)
	    end
	end

	attr_reader :plan, :discarded, :removed
	def initialize(plan)
	    super(plan.hierarchy, plan.service_relations)

	    @plan = plan

	    @removed   = ValueSet.new
	    @discarded = ValueSet.new
	end

	def include?(t); super || super(Proxy.may_wrap(t)) end
	def mission?(t); super || super(Proxy.may_wrap(t)) end

	def missions
	    plan_missions = plan.missions.
		difference(discarded).
		difference(removed)

	    super.union(plan_missions.map(&Proxy.method(:wrap)))
	end

	def known_tasks
	    plan_tasks = plan.known_tasks. 
		difference(removed)

	    super.union(plan_tasks.map(&Proxy.method(:wrap)))
	end


	def insert(t)
	    removed.delete(Proxy.may_unwrap(t))
	    discarded.delete(Proxy.may_unwrap(t))

	    t = if plan.include?(t) then Proxy.wrap(t)
		else Proxy.may_unwrap(t)
		end

	    super(t)
	end

	def discover(t)
	    removed.delete(Proxy.may_unwrap(t))

	    t = if plan.include?(t) then Proxy.wrap(t)
		else Proxy.may_unwrap(t)
		end

	    super(t)
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
		discarded.delete(unwrapped)
		removed.insert(unwrapped)
	    else
		super
	    end
	end

	def commit
	    discarded.each { |t| plan.discard(t) }
	    removed.each { |t| plan.remove_task(t) }

	    as_plan = as(Roby::Plan)

	    # Get all discovered proxies and map their relationship to
	    # their relations present in +plan+
	    TaskStructure.each_relation do |rel|
		tasks = as_plan.known_tasks.find_all do |t| 
		    if Proxy === t 
			t.discovered?(rel)
		    else
			true
		    end
		end

		tasks.each do |proxy|
		    obj = if Proxy === proxy
			      proxy.__getobj__
			  else proxy
			  end

		    proxy_children = proxy.enum_for(:each_child_object, rel).to_a 
		    plan_children  = obj.enum_for(:each_child_object, rel).to_a

		    (proxy_children - plan_children).each do |child|
			unwrapped_child = Proxy.may_unwrap(child)

			if obj != proxy
			    obj.add_child_object(unwrapped_child, rel, proxy[child, rel])
			end

			if unwrapped_child != child
			    proxy.remove_child_object(child, rel)
			end
		    end
		    (plan_children - proxy_children).each do |child|
			obj.remove_child_object(Proxy.may_unwrap(child), rel)
		    end
		end
	    end

	    as_plan.known_tasks.dup.each do |t|
		as_plan.remove_task(t) if Proxy === t
	    end

	    as_plan.missions.each { |t| plan.insert(t) }
	    as_plan.known_tasks.each { |t| plan.discover(t) }
	end
    end
end

