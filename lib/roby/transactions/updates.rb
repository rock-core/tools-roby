module Roby
    class SolverInvalidateTransaction
	def self.finalized_plan_task(trsc, task); end
	def self.finalized_plan_event(trsc, task); end

	def self.adding_plan_relation(trsc, parent, child, type, info)
	end
	def self.removing_plan_relation(trsc, parent, child, type)
	end
    end

    class SolverUpdateRelations
	def self.finalized_plan_task(trsc, task)
	end
	def self.finalized_plan_event(trsc, task)
	end

	def self.adding_plan_relation(trsc, parent, child, type, info)
	    parent_proxy = trsc.wrap(parent)
	    child_proxy  = trsc.wrap(child)
	    type.link(parent_proxy, child_proxy, info)	   
	    trsc.invalid = false
	end
	def self.removing_plan_relation(trsc, parent, child, type)
	    parent_proxy = trsc.wrap(parent)
	    child_proxy  = trsc.wrap(child)
	    type.unlink(parent_proxy, child_proxy)
	    trsc.invalid = false
	end
    end

    class SolverIgnoreUpdate
	def finalized_plan_task(trsc, task)
	    Roby.debug "#{trsc} is valid again"
	    trsc.invalid = false
	end
	def finalized_plan_event(trsc, task)
	    Roby.debug "#{trsc} is valid again"
	    trsc.invalid = false
	end

	def adding_plan_relation(trsc, parent, child, type, info)
	    Roby.debug "#{trsc} is valid again"
	    trsc.invalid = false
	end
	def removing_plan_relation(trsc, parent, child, type)
	    Roby.debug "#{trsc} is valid again"
	    trsc.invalid = false
	end
    end
    class Transaction
	def finalized_plan_task(task)
	    invalidate("task #{task} has been removed from the plan")
	    discard_modifications(task)
	    conflict_solver.finalized_plan_task(self, task)
	end

	def finalized_plan_event(event)
	    invalidate("event #{event} has been removed from the plan")
	    discard_modifications(event)
	    conflict_solver.finalized_plan_event(self, event)
	end

	def adding_plan_relation(parent, child, type, info)
	    invalidate("plan added a relation #{parent} -> #{child} of type #{type} with info #{info}")
	    conflict_solver.adding_plan_relation(self, parent, child, type, info)
	end

	def removing_plan_relation(parent, child, type)
	    invalidate("plan removed the #{parent} -> #{child} relation of type #{type}")
	    conflict_solver.removing_plan_relation(self, parent, child, type)
	end
    end

    module Transactions
	module PlanUpdates
	    def self.finalized_object(plan, object) 
		return unless object.root_object?
		plan.transactions.each do |trsc|
		    next unless trsc.proxying?

		    if trsc.wrap(object, false)
			yield(trsc)
		    end
		end
	    end
	    def finalized_event(event)
		super if defined? super
		PlanUpdates.finalized_object(self, event) { |trsc| trsc.finalized_plan_event(event) }
	    end
	    def finalized_task(task)
		super if defined? super
		PlanUpdates.finalized_object(self, task) { |trsc| trsc.finalized_plan_task(task) }
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

