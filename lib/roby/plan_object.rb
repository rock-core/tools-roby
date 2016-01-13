module Roby
    # Base class for all objects which are included in a plan.
    class PlanObject < DistributedObject
        extend Models::PlanObject
	include Relations::DirectedRelationSupport

        # This object's model
        #
        # This is usually self.class, unless {#specialize} has been called in
        # which case it is this object's singleton class
	attr_reader :model

        # The non-specialized model for self
        #
        # It is always self.class
        def concrete_model; self.class end

        attr_reader :execution_engine

        def connection_space
            if plan
                plan.connection_space
            end
        end

        # Generic handling object for blocks that are stored on tasks (event
        # handlers,poll, ...)
        #
        # The only configurable behaviour so far is the ability to specify what
        # to do with the block when a task is replaced by another one. This is
        # given as a :on_replace option, which can take only two values:
        #
        # drop:: the handler is not copied
        # copy:: the handler is copied
        #
        # The default is dependent on the receiving's object state. For
        # instance, abstract tasks will use a default of 'copy' while
        # non-abstract one will use a default of 'drop'.
        class InstanceHandler
            # The poll Proc object
            attr_reader :block
            ## :method:copy_on_replace?
            #
            # If true, this poll handler gets copied to the new task when the
            # task holding the handler gets replaced
            attr_predicate :copy_on_replace?, true

            # Helper method for validate_options and filter_options
            #
            # @param [:validate,:filter] method which of the filter_options or
            #   validate_options should be called.
            # @!macro InstanceHandlerOptions
            #   @option options [:copy,:drop] :on_replace defines the behaviour
            #      when this object gets replaced in the plan. If :copy is used,
            #      the handler is added to the replacing task and is also kept
            #      in the original task. If :drop, it is not copied (but is
            #      kept).
            def self.handle_options(method, options, defaults)
                options, other = Kernel.send("#{method}_options", options,
                    on_replace: (defaults[:on_replace] || :drop))

                if ![:drop, :copy].include?(options[:on_replace])
                    raise ArgumentError, "wrong value for the :on_replace option. Expecting either :drop or :copy, got #{options[:on_replace]}"
                end

                if other
                    return options, other
                else return options
                end
            end

            def self.validate_options(options, defaults = Hash.new)
                handle_options(:validate, options, defaults)
            end

            def self.filter_options(options, defaults)
                handle_options(:filter, options, defaults)
            end

            def initialize(block, copy_on_replace)
                @block, @copy_on_replace =
                    block, copy_on_replace
            end

            # Creates an option hash from this poll handler parameters that is
            # valid for Task#poll
            def as_options
                on_replace = if copy_on_replace? then :copy
                             else :drop
                             end

                { on_replace: on_replace }
            end

            def ==(other)
                @copy_on_replace == other.copy_on_replace? &&
                    @block == other.block
            end
        end

        def initialize(plan: TemplatePlan.new)
            super()

            @plan = plan
            self.plan = @plan

            @removed_at = nil
            @executable = nil
            @finalization_handlers = Array.new
            @model = self.class
        end

        def initialize_copy(other)
            # Consider whether subclasses initialized the plan before calling us
            # ... in which case we handle it specially and propagate it
            super
            @plan = nil
            @relation_graphs = nil
            @finalization_handlers = other.finalization_handlers.dup
        end

	# The plan this object belongs to
	attr_reader :plan

        # The engine which acts on +plan+ (if there is one)
        def engine; plan.execution_engine if plan && plan.executable? end

        # True if this object is a transaction proxy, false otherwise
        def transaction_proxy?; false end

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
                if PlanObject.debug_finalization_place?
                    raise ArgumentError, "#{self} has been removed from plan, cannot add it back\n" +
                        "Removed at\n  #{removed_at.join("\n  ")}"
                else
                    raise ArgumentError, "#{self} has been removed from plan, cannot add it back. Set PlanObject.debug_finalization_place to true to get the backtrace of where (in the code) the object got finalized"
                end
	    end
            @addition_time = Time.now
	    @plan = new_plan
            @execution_engine =
                if new_plan && new_plan.executable?
                    new_plan.execution_engine
                end
	end

        # Used in plan management as a way to extract a plan object from any
        # object
        def as_plan; self end

        # If +self+ is a transaction proxy, returns the underlying plan object,
        # regardless of how many transactions there is on the stack. Otherwise,
        # return self.
        def real_object
            result = self
            while result.respond_to?(:__getobj__)
                result = result.__getobj__
            end
            result
        end

        # Returns the stack of transactions/plans this object is part of,
        # starting with self.plan.
        def transaction_stack
            result = [plan]
            obj    = self
            while obj.respond_to?(:__getobj__)
                obj = obj.__getobj__
                result << obj.plan
            end
            result
        end

        def each_in_neighbour_merged(relation, intrusive: nil, &block)
            if intrusive.nil?
                raise ArgumentError, "you must give a true or false to the intrusive flag"
            end
            merged_relations(
                proc { |o, &b| o.each_in_neighbour(relation, &b) },
                intrusive, &block)
        end

        def each_out_neighbour_merged(relation, intrusive: nil, &block)
            if intrusive.nil?
                raise ArgumentError, "you must give a true or false to the intrusive flag"
            end
            merged_relations(
                proc { |o, &b| o.each_out_neighbour(relation, &b) },
                intrusive, &block)
        end

        # call-seq:
        #   merged_relation(enumeration_method, false[, arg1, arg2]) do |self_t, related_t|
        #   end
        #   merged_relation(enumeration_method, true[, arg1, arg2]) do |related_t|
        #   end
        #
        # It is assumed that +enumeration_method+ is the name of a method on
        # +self+ that will yield an object related to +self+.
        #
        # This method computes the same set of related objects, but does so
        # while merging all the changes that underlying transactions may have
        # applied. I.e. it is equivalent to calling +enumeration_method+ on the
        # plan that would be the result of the application of the whole
        # transaction stack
        #
        # If +instrusive+ is false, the edges are yielded at the level they
        # appear. I.e. both +self+ and the related object are given, and
        # [self_t, related_t] may be part of a parent plan of self.plan. I.e.
        # +self_t+ is either +self+ itself, or the task that +self+ represents
        # in a parent plan / transaction.
        #
        # If +instrusive+ is true, the related objects are recursively added to
        # all transactions in the transaction stack, and are given at the end.
        # I.e. only the related object is yield, and it is guaranteed to be
        # included in self.plan.
        #
        # For instance,
        #
        #   merged_relations(:each_child, false) do |parent, child|
        #      ...
        #   end
        #
        # yields the children of +self+ according to the modifications that the
        # transactions apply, but may do so in the transaction's parent plans.
        #
        #   merged_relations(:each_child, true) do |child|
        #      ...
        #   end
        #
        # Will yield the same set of tasks, but included in +self.plan+.
        def merged_relations(enumerator, intrusive)
            return enum_for(__method__, enumerator, intrusive) if !block_given?

            plan_chain = self.transaction_stack
            object     = self.real_object
            enumerator = enumerator.to_proc

            pending = Array.new
            while plan_chain.size > 1
                plan      = plan_chain.pop
                next_plan = plan_chain.last

                # Objects that are in +plan+ but not in +next_plan+ are
                # automatically added, as +next_plan+ is not able to change
                # them. Those that are included in +next_plan+ are handled
                # later.
                new_objects = Array.new
                enumerator.call(object) do |related_object|
                    next if next_plan[related_object, false]

                    if !intrusive
                        yield(object, related_object)
                    else
                        new_objects   << related_object
                    end
                end

                # Here, pending contains objects from the previous plan (i.e. in
                # plan.plan). Proxy them in +plan+.
                #
                # It is important to do that *after* we enumerated the relations
                # that exist in +plan+ (above), as it reduces the number of
                # relations at each level.
                pending.map! { |t| plan[t] }
                # And add the new objects that we just discovered
                pending.concat(new_objects)

                if next_plan
                    object = next_plan[object]
                end
            end

            if intrusive
                enumerator.call(self, &Proc.new)
                for related_object in pending
                    yield(self.plan[related_object])
                end
            else
                enumerator.call(self) do |related_object|
                    yield(self, related_object)
                end
            end
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

        # Method called to apply modifications needed to commit this object into
        # the underlying plan
        #
        # For instance, {Task} will make sure that argument objects that are
        # transaction proxies are unwrapped
        #
        # Note that the method should only deal with modifications that are
        # internal to the task itself. Modifications of the relation graphs are
        # handled by {Transaction} itself in
        # {Transaction#apply_modifications_to_plan}
        #
        # The default implementation does nothing
        def commit_transaction
        end

        alias :__freeze__ :freeze

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
	    return if plan == other.plan

            if other.plan.template?
                plan.add(other)
            elsif plan.template?
                other.plan.add(self)
            else
                raise RuntimeError, "cannot add a relation between two objects from different plans. #{self} is from #{plan} and #{other} is from #{other.plan}"
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
                if !type.kind_of?(Class)
                    # If given a graph, we need to re-resolve it as #plan might
                    # have changed
                    type = relation_graphs.fetch(type.class)
                end
	    end

	    super
	end

        # Return the root plan object for this object.
	def root_object; self end
        # True if this object is a root object in the plan.
	def root_object?; root_object == self end
        # Iterates on all the children of this root object
	def each_plan_child; self end

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
                next if rel.copy_on_replace?

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
        # {Relations::DirectedRelationSupport}.
	def replace_subplan_by(object)
            raise NotImplementedError, "#{self.class} did not reimplement #replace_subplan_by"
	end

        # Replaces +self+ by +object+ in all graphs +self+ is part of.
        def replace_by(object)
            raise NotImplementedError, "#{self.class} did not reimplement #replace_by"
	end

        # Called by #replace_by and #replace_subplan_by to do object-specific
        # initialization of +object+ when +object+ is used to replace +self+ in
        # a plan
        #
        # The default implementation does nothing
        def initialize_replacement(object)
            finalization_handlers.each do |handler|
                if handler.copy_on_replace?
                    object ||= yield
                    object.when_finalized(handler.as_options, &handler.block)
                end
            end
        end

        # True if this object can be modified by the local plan manager
	def read_write?
	    if self_owned?
		true
	    elsif plan.self_owned?
                owners.all? { |p| plan.owned_by?(p) }
	    end
	end

        # @return [Array<InstanceHandler>] set of finalization handlers defined
        #   on this task instance
        # @see when_finalized
        attr_reader :finalization_handlers

        # Enumerates the finalization handlers that should be applied in
        # finalized!
        #
        # @yieldparam [#call] block the handler's block
        # @return [void]
        def each_finalization_handler(&block)
            finalization_handlers.each do |handler|
                yield(handler.block)
            end
            self.class.each_finalization_handler do |model_handler|
                model_handler.bind(self).call(&block)
            end
        end

        # Called when a particular object has been removed from its plan
        #
        # If PlanObject.debug_finalization_place? is true (set with
        # {PlanObject.debug_finalization_place=}, the backtrace in this call is
        # stored in {PlanObject#removed_at}. It is false by default, as it is
        # pretty expensive.
        # 
        # @param [Time,nil] timestamp the time at which it got finalized. It is stored in
        #   {#finalization_time}
        # @return [void]
        def finalized!(timestamp = nil)
            if self.plan.executable?
                # call finalization handlers
                each_finalization_handler do |handler|
                    handler.call(self)
                end
            end

            if root_object?
                self.plan = nil
                if PlanObject.debug_finalization_place?
                    self.removed_at = caller
                else
                    self.removed_at = []
                end
                self.finalization_time = timestamp || Time.now
                self.finalized = true
            end
        end

        # Called when the task gets finalized, i.e. removed from the main plan
        #
        # @option options [:copy,:drop] :on_replace (:drop) behaviour to be
        #   followed when the task gets replaced. If :drop, the handler is not
        #   passed, if :copy it is installed on the new task as well as kept on
        #   the old one
        # @yieldparam [Roby::Task] task the task that got finalized. It might be
        #   different than the one on which the handler got installed because of
        #   replacements
        # @return [void]
        def when_finalized(options = Hash.new, &block)
            options = InstanceHandler.validate_options options
            check_arity(block, 1)
            finalization_handlers << InstanceHandler.new(block, (options[:on_replace] == :copy))
        end

        # True if this plan object has been finalized (i.e. removed from plan),
        # or false otherwise
        attr_predicate :finalized?, true

        # The time at which this plan object has been added into its first plan
        attr_accessor :addition_time

        # The time at which this plan object has been finalized (i.e. removed
        # from plan), or nil if it has not been (yet)
        attr_accessor :finalization_time

        # @return [Boolean] true if this object provides all the given models
        def fullfills?(models)
            Array(models).all? do |m|
                self.model <= m
            end
        end
    end
end

