module Roby
    class PlanObject
	# The plan this object belongs to
	attr_reader :plan

	# Set the plan this task is part of
	def plan=(new_plan)
	    @plan = new_plan
	end
	
	# A three-state flag with the following values:
	# nil:: the object is executable if its plan is
	# true:: the object is executable
	# false:: the object is not executable
	attr_writer :executable

	# If this object is executable
	def executable?
	    @executable || (@executable.nil? && plan && plan.executable?)
	end
	
	# Checks that we do not link two objects from two different plans
	# and updates the +plan+ attribute accordingly
	def adding_child_object(child, type, info)
	    return if plan == child.plan

	    if child.plan && plan
		raise InvalidPlanOperation, "cannot add a relation between two objects from different plans. #{self} is from #{plan} and #{child} is from #{child.plan}"
	    elsif child.plan
		child.plan.discover(self)
	    elsif plan
		plan.discover(child)
	    end
	    super if defined? super
	end
    end
end


