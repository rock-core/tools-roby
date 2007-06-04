require 'roby/relations'
require 'roby/distributed/base'
require 'roby/basic_object'

module Roby
    class OwnershipError         < RuntimeError; end
    class NotOwner               < OwnershipError; end

    class PlanObject < BasicObject
	include DirectedRelationSupport

	# The plan this object belongs to
	attr_reader :plan
	# The place where this object has been removed from its plan
	attr_accessor :removed_at

	def finalized?; !!removed_at end

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

	# We are also subscribed to a PlanObject if the we are subscribed to
	# the plan itself
	def subscribed?
	    if root_object?
		(plan && plan.subscribed?) ||
		    (!self_owned? && owners.any? { |peer| peer.subscribed_plan? }) ||
		    super
	    else
		root_object.subscribed?
	    end
	end

	def update_on?(peer); (plan && plan.update_on?(peer)) || super end
	def updated_by?(peer); (plan && plan.updated_by?(peer)) || super end
	def remotely_useful?; (plan && plan.remotely_useful?) || super end

	# Checks that we do not link two objects from two different plans
	# and updates the +plan+ attribute accordingly
	def synchronize_plan(other)
	    if plan == other.plan
	    elsif other.plan && plan
		raise InvalidPlanOperation, "cannot add a relation between two objects from different plans. #{self} is from #{plan} and #{other} is from #{other.plan}"
	    elsif plan
		plan = self.plan
		other.instance_variable_set(:@plan, plan)
		other
	    elsif other.plan
		@plan = other.plan
		self
	    end
	end
	protected :synchronize_plan

	def forget_peer(peer)
	    if !root_object?
		raise "#{self} is not root"
	    end

	    each_plan_child do |child|
		child.forget_peer(peer)
	    end
	    super
	end

	def add_child_object(child, type, info = nil)
	    changed = root_object.synchronize_plan(child.root_object)
	    super

	    if changed
		p = plan
		changed.instance_variable_set(:@plan, nil)
		p.discover(changed)
	    end

	rescue Exception
	    if changed
		changed.instance_variable_set(:@plan, nil)
	    end
	    raise
	end

	def root_object; self end
	def root_object?; root_object == self end
	def each_plan_child; self end

	def self.child_plan_object(attribute)
	    class_eval <<-EOD
	    def root_object; #{attribute} end
	    def root_object?; false end
	    def owners; #{attribute}.owners end
	    def distribute?; #{attribute}.distribute? end
	    def plan; #{attribute}.plan end
	    def executable?; #{attribute}.executable? end

	    def subscribed?; #{attribute}.subscribed? end
	    def updated?; #{attribute}.updated? end
	    def updated_by?(peer); #{attribute}.updated_by?(peer) end
	    def update_on?(peer); #{attribute}.update_on?(peer) end
	    def updated_peers; #{attribute}.updated_peers end
	    def remotely_useful?; #{attribute}.remotely_useful? end

	    def forget_peer(peer)
		remove_sibling_for(peer)
	    end
	    def sibling_of(remote_object, peer)
		if !distribute?
		    raise "#{self} is local only"
		end

		add_sibling_for(peer, remote_object)
	    end
	
	    private :plan=
	    private :executable=
	    EOD
	end

	# Replaces +self+ by +object+ in all graphs +self+ is part of. Unlike
	# BGL::Vertex#replace_by, this calls the various add/remove hooks
	# defined in DirectedRelationSupport
	def replace_by(object)
	    all_relations = []
	    each_relation do |rel|
		parents = []
		each_parent_object(rel) do |parent|
		    parents << parent << parent[self, rel]
		end
		children = []
		each_child_object(rel) do |child|
		    children << child << self[child, rel]
		end
		all_relations << rel << parents << children
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

	def read_write?
	    if (owners.include?(Distributed) || Distributed.updating?(root_object) || !plan)
		true
	    elsif plan.owners.include?(Distributed)
		for peer in owners
		    return false unless plan.owners.include?(peer)
		end
		true
	    end
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

