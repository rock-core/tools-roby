module Roby
    class Transaction
	def finalized_plan_task(task)
	    invalidate("task #{task} has been removed from the plan")
	    remove_object(wrap(task))

	    if conflict_solver && conflict_solver.respond_to?(:finalized_plan_task)
		conflict_solver.finalized_plan_task(task)
	    end
	end
	def finalized_plan_event(event)
	    invalidate("event #{event} has been removed from the plan")
	    remove_object(wrap(event))

	    if conflict_solver && conflict_solver.respond_to?(:finalized_plan_event)
		conflict_solver.finalized_plan_event(event)
	    end
	end

	def adding_plan_relation(parent, child, type, info)
	    case on_plan_update
	    when :invalidate
		invalidate("plan added a relation #{parent} -> #{child} of type #{type} with info #{info}")
	    when :update
		parent_proxy = wrap(parent)
		child_proxy  = wrap(child)
		type.link(parent_proxy, child_proxy, info)	   
	    when :solver
		invalidate("plan added a relation #{parent} -> #{child} of type #{type} with info #{info}")
		conflict_solver.adding_plan_relation(parent, child, type, info)
	    end
	end

	def removing_plan_relation(parent, child, type)
	    case on_plan_update
	    when :invalidate
		invalidate("plan removed the #{parent} -> #{child} relation of type #{type}")
	    when :update
		parent_proxy = wrap(parent)
		child_proxy  = wrap(child)
		type.unlink(parent_proxy, child_proxy)
	    when :solver
		invalidate("plan removed the #{parent} -> #{child} relation of type #{type}")
		conflict_solver.removing_plan_relation(parent, child, type)
	    end
	end
    end

    module Transactions
	module PlanUpdates
	    def finalized_object(object) 
		return unless object.root_object?
		transactions.each do |trsc|
		    next unless trsc.proxying?

		    if trsc.discovered_relations_of?(object, nil, false)
			yield(trsc)
		    end
		end
	    end
	    def finalized_event(event)
		super if defined? super
		finalized_object(event) { |trsc| trsc.finalized_plan_event(event) }
	    end
	    def finalized_task(task)
		super if defined? super
		finalized_object(task) { |trsc| trsc.finalized_plan_task(task) }
	    end
	end
	Roby::Plan.include PlanUpdates

	module PlanObjectUpdates
	    def adding_child_object(child, type, info)
		super if defined? super
		return if !plan

		plan.transactions.each do |trsc|
		    next unless trsc.proxying?
		    if trsc.discovered_relations_of?(self, type, true) || trsc.discovered_relations_of?(child, type, true)
			trsc.adding_plan_relation(self, child, type, info) 
		    end
		end
	    end
	    def removing_child_object(child, type)
		super if defined? super
		return if !plan

		plan.transactions.each do |trsc|
		    next unless trsc.proxying?
		    if trsc.discovered_relations_of?(self, type, true) || trsc.discovered_relations_of?(child, type, true)
			trsc.removing_plan_relation(self, child, type) 
		    end
		end
	    end
	end
	Roby::PlanObject.include PlanObjectUpdates
    end
end

