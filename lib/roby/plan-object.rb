require 'roby/relations'
require 'roby/distributed/base'

module Roby
    class OwnershipError         < RuntimeError; end
    class NotOwner               < OwnershipError; end

    class PlanObject
	include DirectedRelationSupport

	# The plan this object belongs to
	attr_reader :plan
	# The place where this object has been removed from its plan
	attr_accessor :removed_at

	# Sets the new plan. Since it is forbidden to re-use a plan object that
	# has been removed from a plan, it raises ArgumentError if it is the
	# case
	def plan=(new_plan)
	    if removed_at
		raise ArgumentError, "#{self} has been removed from plan, cannot add it back\n" +
		    "Removed at\n  #{removed_at.join("\n  ")}"
	    end
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
	def synchronize_plan(other)
	    if plan == other.plan
	    elsif other.plan && plan
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

	rescue Exception
	    if changed
		changed.instance_eval { @plan = nil }
	    end
	    raise

	else
	    if changed
		p = plan
		changed.instance_eval { @plan = nil }
		changed.plan = p
		p.discover(changed)
	    end
	end

	def root_object; self end
	def root_object?; root_object == self end
	def each_plan_child; self end

	def self.child_plan_object(attribute)
	    class_eval <<-EOD
	    alias root_object #{attribute}
	    def root_object?; false end
	    def read_write?; #{attribute}.read_write? end
	    def owners; #{attribute}.owners end
	    def local?; #{attribute}.local? end
	    def distribute?; #{attribute}.distribute? end
	    def subscribed?; #{attribute}.subscribed? end
	    def plan; #{attribute}.plan end
	    private :plan=
	    def executable?; #{attribute}.executable? end
	    EOD
	end

	# Replaces +self+ by +object+ in all graphs +self+ is part of. Unlike
	# BGL::Vertex#replace_by, this calls the various add/remove hooks
	# defined in DirectedRelationSupport
	def replace_by(object)
	    all_relations = []
	    each_relation do |rel|
		all_relations << rel << 
		    parent_objects(rel).inject([]) { |result, parent| result << parent << parent[self, rel] } << 
		    child_objects(rel).inject([])  { |result, child| result << child << self[child, rel] }
	    end
	    remove_relations

	    all_relations.each_slice(3) do |rel, parents, children|
		parents.each_slice(2) do |parent, info|
		    next if parent.root_object == root_object
		    parent.add_child_object(object, rel, info)
		end
		children.each_slice(2) do |child, info|
		    next if child.root_object == root_object
		    object.add_child_object(child, rel, info)
		end
	    end
	end

	# True if this object can be modified in the current context
	def read_write?
	    Distributed.updating?([root_object]) ||
		Distributed.owns?(self) ||
		!plan ||
		(Distributed.owns?(plan) && (owners - plan.owners).empty?)
	end
	
	# We can remove relation if one of the objects is owned by us
	def removing_child_object(child, type)
	    super if defined? super

	    unless read_write? || child.read_write?
		raise NotOwner, "cannot remove a relation between two objects we don't own"
	    end
	end
    end
end

