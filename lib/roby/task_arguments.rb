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

        def static?
            @static
        end

        def has_key?(value)
            values.has_key?(value)
        end
        def keys
            values.keys
        end

	def writable?(key, value)
            if has_key?(key)
                !task.model.arguments.include?(key) ||
                    values[key].respond_to?(:evaluate_delayed_argument) && !value.respond_to?(:evaluate_delayed_argument)
            else
                true
            end
	end

        def slice(*args)
            evaluate_delayed_arguments.slice(*args)
        end

	def dup; self.to_hash end
	def to_hash
	    values.dup
	end

	def set?(key)
	    has_key?(key) && !values.fetch(key).respond_to?(:evaluate_delayed_argument)
	end

        def ==(hash)
            to_hash == hash.to_hash
        end

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

	def each_static
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

	def update!(key, value)
            values[key] = value
        end

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
		updated

                if update_static
                    @static = values.all? { |k, v| !v.respond_to?(:evaluate_delayed_argument) }
                end
                value
	    else
		raise ArgumentError, "cannot override task argument #{key} as it is already set to #{values[key]}"
	    end
	end
	def updating; super if defined? super end
	def updated; super if defined? super end

        def [](key)
            key = key.to_sym if key.respond_to?(:to_str)
            value = values[key]
            if !value.respond_to?(:evaluate_delayed_argument)
                value
            end
        end

        # Returns this argument set, but with the delayed arguments evaluated
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
            "#{@object || 'task'}.#{@methods.map(&:to_s).join(".")}"
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
