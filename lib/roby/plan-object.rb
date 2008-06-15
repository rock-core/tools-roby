module Roby
    # Base class for all objects which are included in a plan.
    class PlanObject < BasicObject
	include DirectedRelationSupport

	# The plan this object belongs to
	attr_reader :plan

        # The engine which acts on +plan+ (if there is one)
        def engine; plan.engine end

        # The place where this object has been removed from its plan. Once an
        # object is removed from its plan, it cannot be added back again.
	attr_accessor :removed_at

        # True if this object has been included in a plan, but has been removed
        # from it since
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

        # The propagation engine object for this. For PlanObject instances, it
        # is always the plan itself.
        def propagation_engine
            plan
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

	# True if we are explicitely subscribed to this object
	def subscribed?
	    if root_object?
		(plan && plan.subscribed?) ||
		    (!self_owned? && owners.any? { |peer| peer.subscribed_plan? }) ||
		    super
	    else
		root_object.subscribed?
	    end
	end

        # True if we should send updates about this object to +peer+
	def update_on?(peer); (plan && plan.update_on?(peer)) || super end
        # True if we receive updates for this object from +peer+
	def updated_by?(peer); (plan && plan.updated_by?(peer)) || super end
        # True if this object is useful for one of our peers
	def remotely_useful?; (plan && plan.remotely_useful?) || super end

        # Checks that we do not link two objects from two different plans and
        # updates the +plan+ attribute accordingly
        #
        # It raises RuntimeError if both objects are already included in a
        # plan, but their plan mismatches.
	def synchronize_plan(other) # :nodoc:
	    if plan == other.plan
	    elsif other.plan && plan
		raise RuntimeError, "cannot add a relation between two objects from different plans. #{self} is from #{plan} and #{other} is from #{other.plan}"
	    elsif plan
		self.plan.discover(other)
	    elsif other.plan
		other.plan.discover(self)
	    end
	end
	protected :synchronize_plan

        # Called when all links to +peer+ should be removed.
	def forget_peer(peer)
	    if !root_object?
		raise ArgumentError, "#{self} is not root"
	    end

	    each_plan_child do |child|
		child.forget_peer(peer)
	    end
	    super
	end

        # Synchronizes the plan of this object from the one of its peer
	def add_child_object(child, type, info = nil) # :nodoc:
	    if child.plan != plan
		root_object.synchronize_plan(child.root_object)
	    end

	    super
	end

        # Return the root plan object for this object.
	def root_object; self end
        # True if this object is a root object in the plan.
	def root_object?; root_object == self end
        # Iterates on all the children of this root object
	def each_plan_child; self end

        # This class method sets up the enclosing class as a child object,
        # with the root object being returned by the given attribute.
        # Task event generators are for instance defined by
        #
        #   class TaskEventGenerator < EventGenerator
        #       # The task this generator belongs to
        #       attr_reader :task
        #
        #       child_plan_object :task
        #   end
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
		    raise ArgumentError, "#{self} is local only"
		end

		add_sibling_for(peer, remote_object)
	    end
	
	    private :plan=
	    private :executable=
	    EOD
	end

        # Transfers a set of relations from this plan object to +object+.
        # +changes+ is formatted as a sequence of <tt>relation, parents,
        # children</tt> slices, where +parents+ and +children+ are sets of
        # objects.
        #
        # For each of these slices, the method removes the
        # <tt>parent->self</tt> and <tt>self->child</tt> edges in the given
        # relation, and then adds the corresponding <tt>parent->object</tt> and
        # <tt>object->child</tt> edges.
	def apply_relation_changes(object, changes)
            # The operation is done in two parts to avoid problems with
            # creating cycles in the graph: first we remove the old edges, then
            # we add the new ones.
	    changes.each_slice(3) do |rel, parents, children|
		parents.each_slice(2) do |parent, info|
		    parent.remove_child_object(self, rel)
		end
		children.each_slice(2) do |child, info|
		    remove_child_object(child, rel)
		end
	    end

	    changes.each_slice(3) do |rel, parents, children|
		parents.each_slice(2) do |parent, info|
		    parent.add_child_object(object, rel, info)
		end
		children.each_slice(2) do |child, info|
		    object.add_child_object(child, rel, info)
		end
	    end
	end

        # Replaces, in the plan, the subplan generated by this plan object by
        # the one generated by +object+. In practice, it means that we transfer
        # all parent edges whose target is +self+ from the receiver to
        # +object+. It calls the various add/remove hooks defined in
        # DirectedRelationSupport.
	def replace_subplan_by(object)
	    changes = []
	    each_relation do |rel|
		parents = []
		each_parent_object(rel) do |parent|
		    unless parent.root_object == root_object
			parents << parent << parent[self, rel]
		    end
		end
		changes << rel << parents << []
	    end

	    apply_relation_changes(object, changes)
	end

        # Replaces +self+ by +object+ in all graphs +self+ is part of. Unlike
        # BGL::Vertex#replace_by, this calls the various add/remove hooks
        # defined in DirectedRelationSupport
	def replace_by(object)
	    changes = []
	    each_relation do |rel|
		parents = []
		each_parent_object(rel) do |parent|
		    unless parent.root_object == root_object
			parents << parent << parent[self, rel]
		    end
		end
		children = []
		each_child_object(rel) do |child|
		    unless child.root_object == root_object
			children << child << self[child, rel]
		    end
		end
		changes << rel << parents << children
	    end

	    apply_relation_changes(object, changes)
	end

        # True if this object can be modified by the local plan manager
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

        # Checks if we have the right to remove a relation. Raises
        # OwnershipError if it is not the case
	def removing_child_object(child, type)
	    super if defined? super

	    unless read_write? || child.read_write?
		raise OwnershipError, "cannot remove a relation between two objects we don't own"
	    end
	end
    end
end

