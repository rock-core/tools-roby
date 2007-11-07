module Roby
    class SolverInvalidateTransaction
	def self.finalized_plan_task(trsc, task); end
	def self.finalized_plan_event(trsc, task); end

	def self.adding_plan_relation(trsc, parent, child, relations, info)
	end
	def self.removing_plan_relation(trsc, parent, child, relations)
	end
    end

    class SolverUpdateRelations
	def self.finalized_plan_task(trsc, task)
	end
	def self.finalized_plan_event(trsc, task)
	end

	def self.adding_plan_relation(trsc, parent, child, relations, info)
	    parent_proxy = trsc.wrap(parent)
	    child_proxy  = trsc.wrap(child)
	    for rel in relations
		rel.link(parent_proxy, child_proxy, info)	   
	    end
	    trsc.invalid = false
	end
	def self.removing_plan_relation(trsc, parent, child, relations)
	    parent_proxy = trsc.wrap(parent)
	    child_proxy  = trsc.wrap(child)
	    for rel in relations
		rel.unlink(parent_proxy, child_proxy)
	    end
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

	def adding_plan_relation(trsc, parent, child, relations, info)
	    Roby.debug "#{trsc} is valid again"
	    trsc.invalid = false
	end
	def removing_plan_relation(trsc, parent, child, relations)
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

	def adding_plan_relation(parent, child, relations, info)
	    missing_relations = relations.find_all do |rel|
		!parent.child_object?(child, rel)
	    end
	    unless missing_relations.empty?
		invalidate("plan added a relation #{parent} -> #{child} in #{relations} with info #{info}")
		conflict_solver.adding_plan_relation(self, parent, child, relations, info)
	    end
	end

	def removing_plan_relation(parent, child, relations)
	    present_relations = relations.find_all do |rel|
		parent.child_object?(child, rel)
	    end
	    unless present_relations.empty?
		invalidate("plan removed the #{parent} -> #{child} relation in #{relations}")
		conflict_solver.removing_plan_relation(self, parent, child, relations)
	    end
	end
    end

    module Transactions
	module PlanUpdates
	    def self.finalized_object(plan, object) 
		return unless object.root_object?
		plan.transactions.each do |trsc|
		    next unless trsc.proxying?

		    if proxy = trsc.wrap(object, false)
			yield(trsc, proxy)
		    end
		end
	    end
	    def finalized_event(event)
		super if defined? super
		PlanUpdates.finalized_object(self, event) { |trsc, proxy| trsc.finalized_plan_event(proxy) }
	    end
	    def finalized_task(task)
		super if defined? super
		PlanUpdates.finalized_object(self, task) { |trsc, proxy| trsc.finalized_plan_task(proxy) }
	    end
	end
	Roby::Plan.include PlanUpdates

	module PlanObjectUpdates
	    def adding_child_object(child, relations, info)
		super if defined? super
		return if !plan

		for trsc in plan.transactions
		    next unless trsc.proxying?
		    if (parent_proxy = trsc[self, false]) && (child_proxy = trsc[child, false])
			trsc.adding_plan_relation(parent_proxy, child_proxy, relations, info) 
		    end
		end
	    end
	    def removing_child_object(child, relations)
		super if defined? super
		return if !plan

		plan.transactions.each do |trsc|
		    next unless trsc.proxying?
		    if (parent_proxy = trsc[self, false]) && (child_proxy = trsc[child, false])
			trsc.removing_plan_relation(parent_proxy, child_proxy, relations) 
		    end
		end
	    end
	end
	Roby::PlanObject.include PlanObjectUpdates
    end
end

