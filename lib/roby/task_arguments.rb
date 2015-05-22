module Roby
    # Class that handles task arguments. They are handled specially as the
    # arguments cannot be overwritten and can not be changed by a task that is
    # not owned.
    #
    # Moreover, two hooks #updating and #updated allow to hook into the argument
    # update system.
    class TaskArguments
	attr_reader :task
        attr_reader :values

	def initialize(task)
	    @task   = task
            @static = true
            @values = Hash.new
	    super()
	end

        # True if none of the argument values are delayed objects
        def static?
            @static
        end

        # True if an argument with that name is assigned, be it a proper value
        # or a delayed value object
        def has_key?(key)
            values.has_key?(key)
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
            if has_key?(key)
                !task.model.arguments.include?(key) ||
                    values[key].respond_to?(:evaluate_delayed_argument) && !value.respond_to?(:evaluate_delayed_argument)
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

	def dup; self.to_hash end
	def to_hash
	    values.dup
	end

        # Tests if a given argument has been set with a proper value (not a
        # delayed value object)
	def set?(key)
	    has_key?(key) && !values.fetch(key).respond_to?(:evaluate_delayed_argument)
	end

        # True if the arguments are equal
        #
        # Both proper values and delayed values have to be equal
        #
        # @return [Boolean]
        def ==(hash)
            to_hash == hash.to_hash
        end

        # Pretty-prints this argument set
        def pretty_print(pp)
            pp.seplist(values) do |keyvalue|
                key, value = *keyvalue
                key.pretty_print(pp)
                pp.text " => "
                value.pretty_print(pp)
            end
        end

        def to_s
            values.to_s
        end

        # @deprecated use {#each_assigned_argument} instead
        def each_static(&block)
            each_assigned_argument(&block)
        end

        # Returns the set of arguments for which a proper value has been
        # assigned
        #
        # @return [Hash]
        def assigned_arguments
            result = Hash.new
            each_assigned_argument do |k, v|
                result[k] = v
            end
            result
        end

        # Enumerates the arguments that have been explicitly assigned
	def each_assigned_argument
            return assigned_arguments if !block_given?
	    each do |key, value|
		if !value.respond_to?(:evaluate_delayed_argument)
		    yield(key, value)
		end
	    end
	end

        def each
            values.each do |key, value|
                yield(key, value)
            end
        end

        # Updates the given argument, regardless of whether it is allowed or not
        #
        # @see {#writable?}
        # @param [Symbol] key the argument name
        # @param [Object] value the new argument value
        # @return [Object]
	def update!(key, value)
            values[key] = value
        end

        # Assigns a value to a given argument name
        #
        # The method validates that writing this argument value is allowed
        #
        # @raise OwnershipError if we don't own the task
        # @raise ArgumentError if the argument is already set
	def []=(key, value)
            key = key.to_sym if key.respond_to?(:to_str)
	    if writable?(key, value)
		if !task.read_write?
		    raise OwnershipError, "cannot change the argument set of a task which is not owned #{task} is owned by #{task.owners} and #{task.plan} by #{task.plan.owners}"
		end

                if value.respond_to?(:evaluate_delayed_argument)
                    @static = false
                elsif values.has_key?(key) && values[key].respond_to?(:evaluate_delayed_argument)
                    update_static = true
                end

		updating
		values[key] = value
		updated(key, value)

                if update_static
                    @static = values.all? { |k, v| !v.respond_to?(:evaluate_delayed_argument) }
                end
                value
	    else
		raise ArgumentError, "cannot override task argument #{key} as it is already set to #{values[key]}"
	    end
	end
	def updating; super if defined? super end
	def updated(key, value); super if defined? super end

        def [](key)
            key = key.to_sym if key.respond_to?(:to_str)
            value = values[key]
            if !value.respond_to?(:evaluate_delayed_argument)
                value
            end
        end

        # Returns this argument set, but with the delayed arguments evaluated
        #
        # @return [Hash]
        def evaluate_delayed_arguments
            result = Hash.new
            values.each do |key, val|
                if val.respond_to?(:evaluate_delayed_argument)
                    catch(:no_value) do
                        result[key] = val.evaluate_delayed_argument(task)
                    end
                else
                    result[key] = val
                end
            end
            result
        end

        def force_merge!(hash)
            values.merge!(hash)
        end

	def merge!(hash)
	    values.merge!(hash) do |key, old, new|
		if old == new then old
		elsif writable?(key, new) then new
		else
		    raise ArgumentError, "cannot override task argument #{key}: trying to replace #{old} by #{new}"
		end
	    end
	end

        include Enumerable

        DRoby = Struct.new :values do
            def proxy(peer)
                obj = TaskArguments.new(nil)
                obj.values.merge!(peer.local_object(values))
                obj
            end
        end
        def droby_dump(peer)
            DRoby.new(values.droby_dump(peer))
        end
    end

    # Placeholder that can be used as an argument, to delay the assignation
    # until the task is started
    #
    # This will usually not be used directly. One should use Task.from instead
    class DelayedTaskArgument
        def initialize(&block)
            @block = block
        end

        def evaluate_delayed_argument(task)
            @block.call(task)
        end

        def pretty_print(pp)
            pp.text "delayed_argument_from(#{@block})"
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

        def to_s
            "default(" + if value.nil?
                'nil'
            else value.to_s
            end + ")"
        end
    end

    # Placeholder that can be used to assign an argument from an object's
    # attribute, reading the attribute only when the task is started
    #
    # This will usually not be used directly. One should use Task.from instead
    class DelayedArgumentFromObject < BasicObject
        def initialize(object, weak = true)
            @object = object
            @methods = []
            @expected_class = Object
            @weak = weak
        end

        class DRoby
            def initialize(klass, object, methods, weak)
                @klass, @object, @methods, @weak = klass, object, methods, weak
            end
            def proxy(peer)
                base = @klass.new(peer.local_object(@object), @weak)
                @methods.inject(base) do |delayed_arg, m|
                    delayed_arg.send(m)
                end
            end
        end      

        def droby_dump(peer)
            DRoby.new(self.class,
                Distributed.format(@object, peer),
                @methods,
                @weak)
        end

        def of_type(expected_class)
            @expected_class = expected_class
            self
        end

        def evaluate_delayed_argument(task)
            result = @methods.inject(@object || task) do |v, m|
                if v.respond_to?(m)
                    v.send(m)
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

        def method_missing(m, *args, &block)
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
            "default(#{@object || 'task'}.#{@methods.map(&:to_s).join(".")})"
        end

        def pretty_print(pp)
            pp.text "delayed_argument_from(#{@object || 'task'}.#{@methods.map(&:to_s).join(".")})"
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
    #   task.new(:goal => Roby.from(State).pose.position))
    #
    # will set the task's 'goal' argument from State.pose.position *at the
    # time the task is started*
    #
    # It can also be used as default argument values (in which case
    # Task.from can be used instead of Roby.from):
    #
    #   class MyTask < Roby::Task
    #     argument :goal, :default => from(State).pose.position
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
    #   task.new(:goal => Roby.from_state.pose.position))
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
    #   task.new(:goal => Roby.from_state.pose.position))
    #
    def self.from_conf
	from_state(Conf)
    end
end
