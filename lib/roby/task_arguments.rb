# frozen_string_literal: true

module Roby
    # Management of task arguments
    #
    # This class essentially behaves like a Hash, but with two important
    # caveats:
    # - already set values cannot be modified
    # - some special values ("delayed arguments") allow to provide arguments
    #   whose evaluation is delayed until the value is needed.
    #
    # Write-Once Values
    # =================
    #
    # Once set to a plain object (not a delayed argument, see below), a value
    # cannot be changed. Some methods allow to bypass the relevant checks,
    # but these methods must be considered internal
    #
    # Delayed Arguments
    # =================
    #
    # Objects that respond to a #evaluate_delayed_argument method are handled
    # differently by {TaskArguments}. They are considered "delayed arguments",
    # that is arguments that are essentially not set _yet_, but can be evaluated
    # later (usually at execution time) to determine the argument value.
    #
    # These objects must follow the {DelayedArgument} interface
    #
    # These delayed arguments are handled differently than "plain" arguments in
    # a few ways:
    # - standard hash access methods such as {#[]} will "hide" them, that is
    #   return nil instead of the object
    # - they can be overriden once set using e.g. {#[]=} or {#merge!}, unlike
    #   "plain arguments"
    #
    # In addition, Roby provides a mechanism to fine-tune the way delayed
    # arguments are merged. The {#semantic_merge!} call delegates the merge
    # to the delayed arguments, allowing for instance two default argument
    # to be merged if they have the same value.
    class TaskArguments
        attr_reader :task
        attr_reader :values

        def initialize(task)
            @task   = task
            @static = true
            @values = {}
            super()
        end

        # Checks whether the given object is a delayed argument object
        #
        # @return true if the object has an evaluate_delayed_argument method
        def self.delayed_argument?(obj)
            obj.respond_to?(:evaluate_delayed_argument)
        end

        # True if all the set arguments are plain (not delayed) arguments
        def static?
            @static
        end

        private def warn_deprecated_non_symbol_key(key)
            if !key.kind_of?(Symbol)
                Roby.warn_deprecated "accessing arguments using anything else than a symbol is deprecated", 2
                key.to_sym
            else key
            end
        end

        # Return the value stored for the given key as-is
        #
        # Unlike {#[]}, it does not filter out delayed arguments
        def raw_get(key)
            values[key]
        end

        # @deprecated use {#key?} instead
        def has_key?(key)
            values.key?(key)
        end

        # True if an argument with that name is assigned, be it a proper value
        # or a delayed value object. This is an alias to {#assigned?}
        #
        # This is implemented to be consistent with the Hash API. However,
        # because of the semantics of delayed value objects, prefer {#set?} and
        # {#assigned?}
        def key?(key)
            values.key?(key)
        end

        # The set of argument names that have been assigned so far, either
        # with a proper object or a delayed value object
        def keys
            values.keys
        end

        # True if it is possible to write the given value to the given argument
        #
        # @param [Symbol] key the argument name
        # @param [Object] value the new argument value
        def writable?(key, value)
            if key?(key)
                !task.model.arguments.include?(key) ||
                    TaskArguments.delayed_argument?(values[key])
            else
                true
            end
        end

        # Returns the listed set of arguments
        #
        # @param [Array<Symbol>] args the argument names
        #
        # Delayed arguments are evaluated before it is sliced
        def slice(*args)
            evaluate_delayed_arguments.slice(*args)
        end

        def dup
            self.to_hash
        end

        def to_hash
            values.dup
        end

        # Tests if a given argument has been assigned, that is either has a
        # static value or has a delayed value object
        def assigned?(key)
            key?(key)
        end

        # Tests if a given argument has been set with a proper value (not a
        # delayed value object)
        def set?(key)
            key?(key) && !TaskArguments.delayed_argument?(values.fetch(key))
        end

        # True if the arguments are equal
        #
        # Both proper values and delayed values have to be equal
        #
        # @return [Boolean]
        def ==(other)
            to_hash == other.to_hash
        end

        # Pretty-prints this argument set
        def pretty_print(pp)
            pp.seplist(values) do |keyvalue|
                key, value = *keyvalue
                pp.text "#{key}: "
                value.pretty_print(pp)
            end
        end

        def to_s
            values.sort_by(&:first).map { |k, v| "#{k}: #{v}" }.join(", ")
        end

        # Returns the set of arguments for which a proper value has been
        # assigned
        #
        # @return [Hash]
        # @see each_assigned_argument
        def assigned_arguments
            result = {}
            each_assigned_argument do |k, v|
                result[k] = v
            end
            result
        end

        # Enumerates assigned arguments that are not delayed arguments
        #
        # @yieldparam [Symbol] name the argument name
        # @yieldparam [Object] arg the argument value
        # @see assigned_arguments
        def each_assigned_argument
            return assigned_arguments unless block_given?

            each do |key, value|
                unless TaskArguments.delayed_argument?(value)
                    yield(key, value)
                end
            end
        end

        def each(&block)
            values.each(&block)
        end

        # @api private
        StaticArgumentWrapper = Struct.new :value do
            def evaluate_delayed_argument(task)
                value
            end
        end

        # Return the set of arguments that won't be merged by {#semantic_merge!}
        #
        # @param [TaskArguments] other_args
        # @return [{Symbol => [Object, Object]}] the arguments that
        #   can't be merged
        def semantic_merge_blockers(other_args)
            blockers = values.find_all do |name, arg|
                next(false) unless other_args.key?(name)

                other_arg = other_args.values[name]

                self_delayed  = TaskArguments.delayed_argument?(arg)
                other_delayed = TaskArguments.delayed_argument?(other_arg)
                next(arg != other_arg) unless self_delayed || other_delayed

                if self_delayed && other_delayed
                    if !(arg.strong? ^ other_arg.strong?)
                        !arg.can_merge?(task, other_args.task,
                                        other_arg)
                    else
                        false
                    end
                elsif self_delayed
                    if arg.strong?
                        !arg.can_merge?(task, other_args.task,
                                        StaticArgumentWrapper.new(other_arg))
                    else
                        false
                    end
                elsif other_delayed
                    if other_arg.strong?
                        !other_arg.can_merge?(other_args.task, task,
                                              StaticArgumentWrapper.new(arg))
                    else
                        false
                    end
                end
            end
            blockers.each_with_object({}) do |(name, self_obj), h|
                h[name] = [self_obj, other_args[name]]
            end
        end

        # Checks whether self can be merged with other_args through {#semantic_merge!}
        #
        # @param [TaskArguments] other_args
        # @see semantic_merge! semantic_merge_blockers
        def can_semantic_merge?(other_args)
            semantic_merge_blockers(other_args).empty?
        end

        # Merging method that takes delayed arguments into account
        #
        # Unlike {#merge}, this method will let delayed arguments "merge
        # themselves", by delegating to their {#merge} method. It allows to
        # e.g. propagating default arguments in the merge chain if they are
        # the same.
        #
        # @see can_semantic_merge? semantic_merge_blockers
        def semantic_merge!(other_args)
            current_values = values.dup
            other_task = other_args.task
            values.merge!(other_args.values) do |name, arg, other_arg|
                self_delayed  = TaskArguments.delayed_argument?(arg)
                other_delayed = TaskArguments.delayed_argument?(other_arg)

                if self_delayed && other_delayed
                    if !(arg.strong? ^ other_arg.strong?)
                        arg.merge(task, other_task, other_arg)
                    elsif arg.strong?
                        arg
                    else
                        other_arg
                    end
                elsif self_delayed
                    if arg.strong?
                        arg.merge(task, other_task,
                                  StaticArgumentWrapper.new(other_arg))
                    else
                        other_arg
                    end
                elsif other_delayed
                    if other_arg.strong?
                        other_arg.merge(other_task, task,
                                        StaticArgumentWrapper.new(arg))
                    else
                        arg
                    end
                else
                    arg
                end
            end
            current_values.each do |k, v|
                if (new_value = values[k]) != v
                    task.plan.log(:task_arguments_updated, task, k, new_value)
                end
            end
            (values.keys - current_values.keys).each do |new_k|
                task.plan.log(:task_arguments_updated, task, new_k, values[new_k])
            end
            @static = values.each_value.none? { |v| TaskArguments.delayed_argument?(v) }
            self
        end

        # Updates the given argument, regardless of whether it is allowed or not
        #
        # @see #writable?
        # @param [Symbol] key the argument name
        # @param [Object] value the new argument value
        # @return [Object]
        def update!(key, value)
            if values.key?(key)
                current_value = values[key]
                is_updated    = (current_value != value)
                update_static = TaskArguments.delayed_argument?(current_value)
            else is_updated = true
            end

            values[key] = value
            if is_updated
                task.plan.log(:task_arguments_updated, task, key, value)
            end
            if TaskArguments.delayed_argument?(value)
                @static = false
            elsif update_static
                @static = values.all? { |k, v| !TaskArguments.delayed_argument?(v) }
            end
        end

        # Assigns a value to a given argument name
        #
        # The method validates that writing this argument value is allowed. Only
        # values that have not been set, or have been set with a delayed
        # argument, canb e updated
        #
        # @raise NotMarshallable if the new values cannot be marshalled with
        #   DRoby. All task arguments must be marshallable
        # @raise OwnershipError if we don't own the task
        # @raise ArgumentError if the argument is already set
        def []=(key, value)
            key = warn_deprecated_non_symbol_key(key)
            if writable?(key, value)
                if !value.droby_marshallable?
                    raise NotMarshallable, "values used as task arguments must be "\
                        "marshallable, attempting to set #{key} to #{value} of "\
                        "class #{value.class}, which is not"
                elsif !task.read_write?
                    raise OwnershipError, "cannot change the argument set of a task "\
                        "which is not owned #{task} is owned by #{task.owners} and "\
                        "#{task.plan} by #{task.plan.owners}"
                end

                if TaskArguments.delayed_argument?(value)
                    @static = false
                elsif values.key?(key) && TaskArguments.delayed_argument?(values[key])
                    update_static = true
                end

                values[key] = value
                task.plan.log(:task_arguments_updated, task, key, value)

                if update_static
                    @static = values.all? { |k, v| !TaskArguments.delayed_argument?(v) }
                end
                value
            else
                raise ArgumentError, "cannot override task argument #{key} as it is "\
                    "already set to #{values[key]}"
            end
        end

        # Return a set value for the given key
        #
        # @param [Symbol] key
        # @return [Object,nil] return the set value for key, or nil if the
        #   value is either a delayed argument object (e.g. a default value) or
        #   if no value is set at all
        def [](key)
            key = warn_deprecated_non_symbol_key(key)
            value = values[key]
            value unless TaskArguments.delayed_argument?(value)
        end

        # Returns this argument set, but with the delayed arguments evaluated
        #
        # @return [Hash]
        def evaluate_delayed_arguments
            result = {}
            values.each do |key, val|
                if TaskArguments.delayed_argument?(val)
                    catch(:no_value) do
                        result[key] = val.evaluate_delayed_argument(task)
                    end
                else
                    result[key] = val
                end
            end
            result
        end

        # Merge a hash into the arguments, updating existing values
        #
        # Unlike {#merge!}, this will update existing values. You should not do
        # it, unless you know what you're doing.
        #
        # @raise NotMarshallable if the new values cannot be marshalled with
        #   DRoby. All task arguments must be marshallable
        def force_merge!(hash)
            hash.each do |key, value|
                unless value.droby_marshallable?
                    raise NotMarshallable, "values used as task arguments must "\
                        "be marshallable, attempting to set #{key} to #{value}, "\
                        "which is not"
                end
            end

            if task.plan&.executable?
                values.merge!(hash) do |k, _, v|
                    task.plan.log(:task_arguments_updated, task, k, v)
                    v
                end
            else
                values.merge!(hash)
            end
            @static = values.all? { |k, v| !TaskArguments.delayed_argument?(v) }
        end

        # Merge a hash into the arguments
        #
        # Only arguments that are unset or are currently delayed arguments (such
        # as default arguments) can be updated. If the caller tries ot update
        # other arguments, the method will raise
        #
        # @raise NotMarshallable if the new values cannot be marshalled with
        #   DRoby. All task arguments must be marshallable
        # @raise ArgumentError if the merge would modify an existing value
        def merge!(hash)
            hash.each do |key, value|
                unless value.droby_marshallable?
                    raise NotMarshallable, "values used as task arguments must "\
                        "be marshallable, attempting to set #{key} to #{value}, "\
                        "which is not"
                end
            end

            values.merge!(hash) do |key, old, new|
                if old == new then old
                elsif writable?(key, new)
                    task.plan.log(:task_arguments_updated, task, key, new)
                    new
                else
                    raise ArgumentError, "cannot override task argument #{key}: "\
                        "trying to replace #{old} by #{new}"
                end
            end
            @static = values.all? { |k, v| !TaskArguments.delayed_argument?(v) }
            self
        end

        include Enumerable
    end

    # Documentation of the delayed argument interface
    #
    # This is not meant to be used directly
    class DelayedArgument
        # Pretty-print this delayed argument
        #
        # Roby uses the pretty-print mechanism to build most of its error
        # messages, so it is better to implement the {#pretty_print} method
        # for custom delayed arguments
        def pretty_print(pp); end

        # Evaluate this delayed argument in the context of the given task
        #
        # It should either return a plain object (which may be nil) or
        # throw :no_value to indicate that it cannot be evaluated (yet)
        def evaluate_delayed_argument(task)
            raise NotImplementedError
        end

        # Tests the possibility to merge this with another delayed argument
        #
        # This tests whether this arguemnt, in the context of task, could
        # be merged with another argument when evaluated in the context of
        # another task
        def can_merge?(task, other_task, other_arg)
            raise NotImplementedError
        end

        # Merge this argument with another
        #
        # The method may assume that {#can_merge?} has been called and returned
        # true
        #
        # @return [Object] the merged argument, which may be a delayed argument
        #   itself.
        def merge(task, other_task, other_arg)
            raise NotImplementedError
        end

        # Whether the argument represents a default (weak) or a real value (strong)
        #
        # Strong arguments automatically override weak ones during merge
        def strong?
            raise NotImplementedError
        end
    end

    # Placeholder that can be used as an argument to represent a default value
    class DefaultArgument
        attr_reader :value

        def initialize(value)
            @value = value
        end

        def evaluate_delayed_argument(task)
            value
        end

        def strong?
            false
        end

        def can_merge?(task, other_task, other_arg)
            true
        end

        def merge(task, other_task, other_arg)
            if other_arg.kind_of?(DefaultArgument) # backward-compatible behavior
                self
            else
                other_arg
            end
        end

        def pretty_print(pp)
            pp.text to_s
        end

        def to_s
            "default(#{value.nil? ? 'nil' : value})"
        end

        def ==(other)
            other.kind_of?(self.class) &&
                other.value == value
        end
    end

    # Placeholder that can be used to assign an argument from an object's
    # attribute, reading the attribute only when the task is started
    #
    # This will usually not be used directly. One should use Task.from instead
    class DelayedArgumentFromObject
        def initialize(object, weak = true)
            @object = object
            @methods = []
            @expected_class = Object
            @weak = weak
        end

        def of_type(expected_class)
            @expected_class = expected_class
            self
        end

        def strong?
            true
        end

        def can_merge?(task, other_task, other_arg)
            catch(:no_value) do
                this_evaluated  = evaluate_delayed_argument(task)
                other_evaluated = other_arg.evaluate_delayed_argument(other_task)
                return other_evaluated == this_evaluated
            end
            false
        end

        def merge(task, other_task, other_arg)
            evaluate_delayed_argument(task)
        end

        def evaluate_delayed_argument(task)
            result = @methods.inject(@object || task) do |v, m|
                if v.kind_of?(Roby::Task) && v.model.has_argument?(m)
                    # We are trying to access a task argument, throw no_value if the
                    # argument is not set
                    unless v.arguments.key?(m)
                        throw :no_value
                    end

                    argument = v.arguments.values[m]
                    if TaskArguments.delayed_argument?(argument)
                        argument.evaluate_delayed_argument(v)
                    else
                        argument
                    end
                elsif v.respond_to?(m)
                    begin v.send(m)
                    rescue Exception
                        throw :no_value
                    end
                elsif @weak
                    throw :no_value
                else
                    task.failed_to_start!("#{v} has no method called #{m}")
                    throw :no_value
                end
            end

            if @expected_class && !result.kind_of?(@expected_class)
                throw :no_value
            end
            result
        end

        def method_missing(m, *args)
            if args.empty? && !block_given?
                @methods << m
                self
            else
                super
            end
        end

        def ==(other)
            other.kind_of?(DelayedArgumentFromObject) &&
                @object.object_id == other.instance_variable_get(:@object).object_id &&
                @methods == other.instance_variable_get(:@methods)
        end

        def to_s
            "delayed_argument_from(#{@object || 'task'}.#{@methods.map(&:to_s).join('.')})"
        end

        def pretty_print(pp)
            pp.text to_s
        end
    end

    # Placeholder that can be used to assign an argument from a state value,
    # reading the attribute only when the task is started
    #
    # This will usually not be used directly. One should use Task.from_state instead
    #
    # It differs from DelayedArgumentFromObject as it always filters out
    # unassigned state values
    class DelayedArgumentFromState < DelayedArgumentFromObject
        def initialize(state_object = State, weak = true)
            super(state_object, weak)
        end

        def strong?
            true
        end

        def can_merge?(task, other_task, other_arg)
            other_arg.object == object &&
                other_arg.methods == methods
        end

        def merge(task, other_task, other_arg)
            self
        end

        def evaluate_delayed_argument(task)
            result = super
            if result.kind_of?(OpenStruct) && !result.attached?
                throw :no_value
            end
            result
        end
    end

    # Use to specify that a task argument should be initialized from an
    # object's attribute.
    #
    # For instance,
    #
    #   task.new(goal: Roby.from(State).pose.position))
    #
    # will set the task's 'goal' argument from State.pose.position *at the
    # time the task is started*
    #
    # It can also be used as default argument values (in which case
    # Task.from can be used instead of Roby.from):
    #
    #   class MyTask < Roby::Task
    #     argument :goal, default: from(State).pose.position
    #   end
    #
    # If the provided object is nil, the receiver will be the task itself.
    #
    # @example initialize an argument from the task's parent
    #   MyTaskModel.new(arg: Task.from(:parent_task).parent_arg)
    #
    def self.from(object)
        DelayedArgumentFromObject.new(object)
    end

    # Use to specify that a task argument should be initialized from a value in
    # the State
    #
    # For instance:
    #
    #   task.new(goal: Roby.from_state.pose.position))
    #
    def self.from_state(state_object = State)
        DelayedArgumentFromState.new(state_object)
    end

    # Use to specify that a task argument should be initialized from a value in
    # the Conf object. The value will be taken at the point in time where the
    # task is executed.
    #
    # For instance:
    #
    #   task.new(goal: Roby.from_state.pose.position))
    #
    def self.from_conf
        from_state(Conf)
    end
end
