require 'roby/relations'
require 'roby/distributed/objects'

module Roby
    class PlanObject
	include DirectedRelationSupport

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

	def freeze
	    self.plan = nil
	    super
	end
	
	# Checks that we do not link two objects from two different plans
	# and updates the +plan+ attribute accordingly
	def synchronize_plan(other)
	    return if plan == other.plan

	    if other.plan && plan
		raise InvalidPlanOperation, "cannot add a relation between two objects from different plans. #{self} is from #{plan} and #{other} is from #{other.plan}"
	    elsif plan
		plan = self.plan
		other.instance_eval { @plan = plan }
		other
	    elsif other.plan
		@plan = other.plan
		self
	    end
	end
	protected :synchronize_plan

	def add_child_object(child, type, info = nil)
	    changed = root_object.synchronize_plan(child.root_object)
	    super
	    if changed
		p = plan
		changed.instance_eval { @plan = nil }
		changed.plan = p
		p.discover(changed)
	    end

	rescue Exception
	    if changed
		changed.instance_eval { @plan = nil }
	    end

	    raise
	end

	def root_object; self end
	def root_object?; root_object == self end

	include Distributed::LocalObject
	def read_only?
	    !Distributed.updating?([root_object]) && plan && !(self.owners - plan.owners).empty?
	end
    end
end


