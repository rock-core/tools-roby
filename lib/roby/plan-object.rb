module Roby
    class PlanObject
	# The plan this object belongs to
	attr_accessor :plan

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
	def synchronize_plan(other)
	    return if plan == other.plan

	    if other.plan && plan
		raise InvalidPlanOperation, "cannot add a relation between two objects from different plans. #{self} is from #{plan} and #{other} is from #{other.plan}"
	    elsif plan
		plan.discover(other)
	    elsif other.plan
		other.plan.discover(self)
	    end
	end

	def adding_child_object(child, type, info)
	    synchronize_plan(child)
	    super if defined? super
	end
	def adding_parent_object(parent, type, info)
	    synchronize_plan(parent)
	    super if defined? super
	end

	def root_object; self end
    end
end


