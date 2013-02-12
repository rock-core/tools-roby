module Roby
    TaskService = Models::TaskServiceModel.new
    TaskService.root = true

    # Base class for events emitted by tasks.
    #
    # When one creates a new event on a task, Roby creates a corresponding
    # subclass of TaskEvent. The emitted event objects are then instances of
    # that class.
    #
    # For instance, there is a Roby::Task::StopEvent class which is used to
    # represent the emitted :stop events of Roby::Task. However, if one
    # overloads the stop command with
    #
    #   class TModel < Roby::Task
    #     event :stop, :controlable => true
    #   end
    #
    # Then TModel::StopEvent will be a subclass of StopEvent.
    #
    # These models are meant to be extended when the emission carry
    # information, i.e. to provide a robust access to the information contained
    # in Event#context
    class TaskEvent < Event
        # The task which fired this event
        attr_reader :task
        # The event model, usually its class
        attr_reader :model

        def initialize(task, generator, propagation_id, context, time = Time.now)
            @task = task
	    @terminal_flag = generator.terminal_flag
            @model = self.class
            super(generator, propagation_id, context, time)
        end

	# Returns the events that are the cause of this event, limiting itself
        # to the task's events. The return value is a ValueSet of TaskEvent
        # instances.
        #
        # For instance, for an interruptible task:
        #
        #   task.start!
        #   task.stop!
        #
        # Then task.stop_event.last.task_sources will return a ValueSet instance
        # which contains the failed event. I.e. in this particular situation, it
        # behaves in the same way than Event#event_sources
        #
        # However, with
        #
        #   event.add_signal task.failed_event
        #   task.start!
        #   event.call
        #
        # Event#event_sources will return both event.last and
        # task.failed_event.last while TaskEvent will only return
        # task.failed_event.last.
	def task_sources
	    result = ValueSet.new
            for ev in sources
                gen = ev.generator
                if gen.respond_to?(:task) && gen.task == task
                    result << ev
                end
            end
	    result
	end

        # Recursively browses in the event sources, returning only those that
        # come from this event's task
        def all_task_sources
            result = ValueSet.new
            for ev in task_sources
                result << ev
                result.merge(ev.all_task_sources)
            end
            result
        end

        # Recursively browses in the event sources, returning those (1) that
        # come from this event's task and (2) have no parent from within the
        # Forwarding relation in the task sources.
        def root_task_sources
            all = all_task_sources
            all.find_all do |event|
                all.none? { |ev| ev.generator.child_object?(event.generator, Roby::EventStructure::Forwarding) }
            end
        end

	def to_s
	    result = "[#{Roby.format_time(time)} @#{propagation_id}] #{task}/#{symbol}"
            if context
                result += ": #{context}"
            end
            result
	end

        def pretty_print(pp)
            pp.text "[#{Roby.format_time(time)} @#{propagation_id}] #{task}/#{symbol}"
            if context
                pp.breakable
                pp.nest(2) do
                    pp.text "  "
                    pp.seplist(context) { |v| v.pretty_print(pp) }
                end
            end
        end

        # If the event model defines a controlable event
        # By default, an event is controlable if the model
        # responds to #call
        def self.controlable?; respond_to?(:call) end
        # If the event is controlable
        def controlable?; model.controlable? end
	class << self
	    # Called by Task.update_terminal_flag to update the flag
	    attr_writer :terminal
	end
        # If the event model defines a terminal event
        def self.terminal?; @terminal end
	# If this event is terminal
	def success?; @terminal_flag == :success end
	# If this event is terminal
	def failure?; @terminal_flag == :failure end
	# If this event is terminal
	def terminal?; @terminal_flag end
        # The event symbol
        def self.symbol; @symbol end
        # The event symbol
        def symbol; model.symbol end
    end


    # Specialization of EventGenerator to represent task events
    #
    # It gives access to the task-specific information (associated task, event
    # name, ...)
    class TaskEventGenerator < EventGenerator
	# The task we are part of
        attr_reader :task
	# The event symbol (its name as a Symbol object)
	attr_reader :symbol
        # Changes the underlying model
        def override_model(model)
            @event_model = model
        end

        def initialize(task, model)
	    super(model.respond_to?(:call))
            @task, @event_model = task, model
	    @symbol = model.symbol
        end

        # The default command if the event is created with :controlable => true.
        # It emits the event on the task.
	def default_command(context)
	    event_model.call(task, context)
	end

        def command=(block)
            event_model.singleton_class.class_eval do
                define_method(:call, &block)
            end
        end

	# See PlanObject::child_plan_object. 
	child_plan_object :task

	# The event plan. It is the same as task.plan and is actually updated
	# by task.plan=. It is redefined here for performance reasons.
	attr_accessor :plan

	# Hook called just before the event is emitted. If it raises, the event
        # will not be emitted at all.
        #
        # This forwards the call to Task#emitting_event
        def emitting(context) # :nodoc:
            task.emitting_event(self, context)
            super if defined? super
        end

        def calling(context)
            super if defined? super
            if symbol == :start
                task.freeze_delayed_arguments
            end
        end

        def called(context)
            super if defined? super
            if terminal? && pending?
                task.finishing = true
            end
        end

        # Actually emits the event. This should not be used directly.
        #
        # It forwards the call to Task#fire
        def fired(event) # :nodoc:
            super if defined? super
            task.fired_event(event)
        end

        # See EventGenerator#related_tasks
	def related_tasks(result = nil) # :nodoc:
	    tasks = super
	    tasks.delete(task)
	    tasks
	end

        # See EventGenerator#each_handler
	def each_handler # :nodoc:
	    if self_owned?
		task.model.each_handler(event_model.symbol) { |o| yield(o) }
	    end

	    super
	end

        # See EventGenerator#each_precondition
	def each_precondition # :nodoc:
	    task.model.each_precondition(event_model.symbol) { |o| yield(o) }
	    super
	end

        # See EventGenerator#controlable?
        def controlable? # :nodoc:
            event_model.controlable?
        end

        # Cached value for #terminal?
	attr_writer :terminal_flag # :nodoc:

        # Returns the value for #terminal_flag, updating it if needed
        def terminal_flag # :nodoc:
            if task.invalidated_terminal_flag?
                task.update_terminal_flag
            end
            return @terminal_flag
        end

        # True if this event is either forwarded to or signals the task's :stop event
	def terminal?; !!terminal_flag end
        # True if this event is either forwarded to or signals the task's :success event
	def success?; terminal_flag == :success end
        # True if this event is either forwarded to or signals the task's :failed event
	def failure?; terminal_flag == :failure end

        # Invalidates the task's terminal flag when the Forwarding and/or the
        # Signal relation gets modified.
	def added_child_object(child, relations, info) # :nodoc:
	    super if defined? super

            if !task.invalidated_terminal_flag?
                if (relations.include?(EventStructure::Forwarding) || relations.include?(EventStructure::Signal)) && 
                    child.respond_to?(:task) && child.task == task

                    task.invalidate_terminal_flag
                end
            end
	end

        # Invalidates the task's terminal flag when the Forwarding and/or the
        # Signal relation gets modified.
	def removed_child_object(child, relations)
	    super if defined? super

            if !task.invalidated_terminal_flag?
                if (relations.include?(EventStructure::Forwarding) || relations.include?(EventStructure::Signal)) && 
                    child.respond_to?(:task) && child.task == task

                    task.invalidate_terminal_flag
                end
            end
	end

        # See EventGenerator#new
        def new(context, propagation_id = nil, time = nil) # :nodoc:
            event_model.new(task, self, propagation_id || plan.engine.propagation_id, context, time || Time.now)
        end

	def to_s # :nodoc:
	    "#{task}/#{symbol}"
	end
	def inspect # :nodoc:
	    "#{task.inspect}/#{symbol}: #{history.to_s}"
	end
        def pretty_print(pp) # :nodoc:
            pp.text "#{symbol} event of #{task.class}:0x#{task.address.to_s(16)}"
        end

        # See EventGenerator#achieve_with
	def achieve_with(obj) # :nodoc:
	    child_task, child_event = case obj
				      when Roby::Task then [obj, obj.event(:success)]
				      when Roby::TaskEventGenerator then [obj.task, obj]
				      end

	    if child_task
		unless task.depends_on?(child_task, false)
		    task.depends_on child_task, 
			:success => [child_event.symbol],
			:remove_when_done => true
		end
		super(child_event)
	    else
		super(obj)
	    end
	end

	# Refines exceptions that may be thrown by #call_without_propagation
        def call_without_propagation(context) # :nodoc:
            super
    	rescue EventNotExecutable => e
	    refine_call_exception(e)
        end

	# Checks that the event can be called. Raises various exception
	# when it is not the case.
	def check_call_validity # :nodoc:
            begin
                super
            rescue UnreachableEvent
            end

            if task.failed_to_start?
                raise CommandFailed.new(nil, self), 
		    "#{symbol}! called by #{plan.engine.propagation_sources.to_a} but the task has failed to start."
            elsif task.event(:stop).happened?
                raise CommandFailed.new(nil, self), 
		    "#{symbol}! called by #{plan.engine.propagation_sources.to_a} but the task has finished. Task has been terminated by #{task.event(:stop).history.first.sources}."
            elsif task.finished? && !terminal?
                raise CommandFailed.new(nil, self), 
		    "#{symbol}! called by #{plan.engine.propagation_sources.to_a} but the task has finished. Task has been terminated by #{task.event(:stop).history.first.sources}."
            elsif task.pending? && symbol != :start
                raise CommandFailed.new(nil, self), 
		    "#{symbol}! called by #{plan.engine.propagation_sources.to_a} but the task has never been started"
            elsif task.running? && symbol == :start
                raise CommandFailed.new(nil, self), 
		    "#{symbol}! called by #{plan.engine.propagation_sources.to_a} but the task is already running. Task has been started by #{task.event(:start).history.first.sources}."
            end

    	rescue EventNotExecutable => e
	    refine_call_exception(e)
	end

	# Checks that the event can be emitted. Raises various exception
	# when it is not the case.
	def check_emission_validity # :nodoc:
  	    super
    	rescue EventNotExecutable => e
	    refine_emit_exception(e)
    	end

        # When an emissio and/or call exception is raised by the base
        # EventGenerator methods, this method is used to transform it to the
        # relevant task-related error.
	def refine_call_exception (e) # :nodoc:
	    if task.partially_instanciated?
		raise TaskEventNotExecutable.new(self), "#{symbol}! called on #{task} which is partially instanciated\n" + 
			"The following arguments were not set: \n" +
			task.list_unset_arguments.map {|n| "\t#{n}"}.join("\n")+"\n"
	    elsif !plan
		raise TaskEventNotExecutable.new(self), "#{symbol}! called on #{task} but the task is in no plan"
	    elsif !plan.executable?
		raise TaskEventNotExecutable.new(self), "#{symbol}! called on #{task} but the plan is not executable"
	    elsif task.abstract?
		raise TaskEventNotExecutable.new(self), "#{symbol}! called on #{task} but the task is abstract"
	    else
		raise TaskEventNotExecutable.new(self), "#{symbol}! called on #{task} which is not executable: #{e.message}"
	    end
	end

        # When an emissio and/or call exception is raised by the base
        # EventGenerator methods, this method is used to transform it to the
        # relevant task-related error.
	def refine_emit_exception (e) # :nodoc:
	    if task.partially_instanciated?
		raise TaskEventNotExecutable.new(self), "emit(#{symbol}) called on #{task} which is partially instanciated\n" + 
			"The following arguments were not set: \n" +
			task.list_unset_arguments.map {|n| "\t#{n}"}.join("\n")+"\n"
	    elsif !plan
		raise TaskEventNotExecutable.new(self), "emit(#{symbol}) called on #{task} but the task is in no plan"
	    elsif !plan.executable?
		raise TaskEventNotExecutable.new(self), "emit(#{symbol}) called on #{task} but the plan is not executable"
	    elsif task.abstract?
		raise TaskEventNotExecutable.new(self), "emit(#{symbol}) called on #{task} but the task is abstract"
	    else
		raise TaskEventNotExecutable.new(self), "emit(#{symbol}) called on #{task} which is not executable: #{e.message}"
	    end
	end

        def on(options = Hash.new, &block)
            default_on_replace =
                if task.abstract? then :copy
                else :drop
                end
            on_replace, options = Kernel.filter_options options, :on_replace => default_on_replace
            super(on_replace.merge(options), &block)
        end
    end

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

    # In a plan, Task objects represent the activities of the robot. 
    # 
    # === Task models
    #
    # A task model is mainly described by:
    #
    # <b>a set of named arguments</b>, which are required to parametrize the
    # task instance. The argument list is described using Task.argument and
    # arguments are either set at object creation by passing an argument hash
    # to Task.new, or by calling Task#argument explicitely.
    #
    # <b>a set of events</b>, which are situations describing the task
    # progression.  The base Roby::Task model defines the
    # +start+,+success+,+failed+ and +stop+ events. Events can be defined on
    # the models by using Task.event:
    #
    #   class MyTask < Roby::Task
    #       event :intermediate_event
    #   end
    #
    # defines a non-controllable event, i.e. an event which can be emitted, but
    # cannot be triggered explicitely by the system. Controllable events are defined
    # by associating a block of code with the event, this block being responsible for
    # making the event emitted either in the future or just now. For instance,
    #
    #   class MyTask < Roby::Task
    #       event :intermediate_event do |context|
    #           emit :intermediate_event
    #       end
    #
    #       event :other_event do |context|
    #           engine.once { emit :other_event }
    #       end
    #   end
    #
    # define two controllable event. In the first case, the event is
    # immediately emitted, and in the second case it will be emitted at the
    # beginning of the next execution cycle.
    #
    # === Task relations
    #
    # Task relations are defined in the TaskStructure RelationSpace instance.
    # See TaskStructure documentation for the list of special methods defined
    # by the various graphs, and the TaskStructure namespace for the name and
    # purpose of the various relation graphs themselves.
    #
    # === Executability
    #
    # By default, a task is not executable, which means that no event command
    # can be called and no event can be emitted. A task becomes executable
    # either because Task#executable= has explicitely been called or because it
    # has been inserted in a Plan object. Note that forcing executability with
    # #executable= is only useful for testing. When the Roby controller manages
    # a real systems, the executability property enforces the constraint that a
    # task cannot be executed outside of the plan supervision. 
    #
    # Finally, it is possible to describe _abstract_ task models: tasks which
    # do represent an action, but for which the _means_ to perform that action
    # are still unknown. This is done by calling Task.abstract in the task definition:
    #
    #   class AbstTask < Roby::Task
    #       abstract
    #   end
    #
    # An instance of an abstract model cannot be executed, even if it is included
    # in a plan.
    #
    # === Inheritance rules
    #
    # On task models, a submodel can inherit from a parent model if the actions
    # described by the parent model are also performed by the child model. For
    # instance, a <tt>Goto(x, y)</tt> model could be subclassed into a
    # <tt>Goto::ByFoot(x, y)</tt> model.
    #
    # The following constraints apply when subclassing a task model:
    # * a task subclass has at least the same events than the parent class
    # * changes to event attributes are limited. The rules are:
    #   - a controlable event must remain controlable. Nonetheless, a
    #     non-controlable event can become a controlable one
    #   - a terminal event (i.e. a terminal event which ends the task
    #     execution) cannot become non-terminal. Nonetheless, a non-terminal
    #     event can become terminal.
    #
    class Task < PlanObject
        extend Models::Task
        provides TaskService

	# The task arguments as symbol => value associative container
	attr_reader :arguments

	# The part of +arguments+ that is meaningful for this task model. I.e.
        # it returns the set of elements in the +arguments+ property that define
        # arguments listed in the task model
	def meaningful_arguments(task_model = self.model)
            task_model.meaningful_arguments(arguments)
	end

        # Called when the start event get called, to resolve the delayed
        # arguments (if there is any)
        def freeze_delayed_arguments
            if !arguments.static?
                arguments.dup.each do |key, value|
                    if value.respond_to?(:evaluate_delayed_argument)
                        __assign_argument__(key, value.evaluate_delayed_argument(self))
                    end
                end
            end
        end

	# The task name
	def name
	    @name ||= "#{model.name || self.class.name}:0x#{address.to_s(16)}"
	end
	
	# This predicate is true if this task is a mission for its owners. If
	# you want to know if it a mission for the local system, use Plan#mission?
	attr_predicate :mission?, true

	def inspect
	    state = if pending? then 'pending'
		    elsif failed_to_start? then 'failed to start'
		    elsif starting? then 'starting'
		    elsif running? then 'running'
		    elsif finishing? then 'finishing'
		    else 'finished'
		    end
	    "#<#{to_s} executable=#{executable?} state=#{state} plan=#{plan.to_s}>"
	end

        # Internal helper to set arguments by either using the argname= accessor
        # if there is one, or direct access to the @arguments instance variable
        def __assign_argument__(key, value) # :nodoc:
            key = key.to_sym
            if self.respond_to?("#{key}=")
                self.send("#{key}=", value)
            else
                @arguments[key] = value
            end
        end

	
        # Builds a task object using this task model
	#
        # The task object can be configured by a given block. After the 
        # block is called, two things are checked:
        # * the task shall have a +start+ event
        # * the task shall have at least one terminal event. If no +stop+ event
        #   is defined, then all terminal events are aliased to +stop+
        def initialize(arguments = Hash.new) #:yields: task_object
	    super() if defined? super
	    @model   = self.class
            @abstract = @model.abstract?
            
            @started = false
            @finished = false
            @finishing = false
            @success = nil
            @reusable = true

	    @arguments = TaskArguments.new(self)
            # First assign normal values
            arguments.each do |key, value|
                __assign_argument__(key, value)
            end
            # Now assign default values for the arguments that have not yet been
            # set
            model.arguments.each do |argname|
                next if @arguments.has_key?(argname)

                has_default, default = model.default_argument(argname)
                if has_default
                    __assign_argument__(argname, default)
                end
            end

            @poll_handlers = []
            @execute_handlers = []

            yield(self) if block_given?

            @terminal_flag_invalid = true

            # Create the EventGenerator instances that represent this task's
            # events. Note that the event relations are instanciated by
            # Plan#discover when this task is included in a plan, thus avoiding
            # filling up the relation graphs with unused relations.
	    initialize_events
	    
            if machine = ::Roby::TaskStateMachine.from_model(self.class)
                instance_variable_set(:@state_machine, machine)
            end
	end
        
	# Retrieve the current state of the task 
	# Can be one of the core states: pending, failed_to_start, starting, started, running, finishing, 
	# succeeded or failed
	# In order to add substates to +running+ TaskStateMachine#refine_running_state 
	# can be used. 
	def current_state
	    # Started and not finished
	    if running? 
		if respond_to?("state_machine")
                    # state_machine.status # => String
                    # state_machine.status_name # => Symbol
		    return state_machine.status_name
		else
		    return :running
		end
	    end
	
	    # True, when task has never been started
	    if pending? 
		return :pending 
            elsif failed_to_start? 
		return :failed_to_start
            elsif starting?
	        return :starting
	    # True, when terminal event is pending
            elsif finishing? 
	        return :finishing
	    # Terminated with success or failure
            elsif success? 
	        return :succeeded
            elsif failed? 
	        return :failed 
	    end
	end

	# Test if that current state corresponds to the provided state (symbol)
	def current_state?(state) 
	    return state == current_state.to_sym
	end

        # Helper methods which creates all the necessary TaskEventGenerator
        # objects and stores them in the #bound_events map
	def initialize_events # :nodoc:
	    @instantiated_model_events = false

	    # Create all event generators
	    bound_events = Hash.new
	    model.each_event do |ev_symbol, ev_model|
		bound_events[ev_symbol.to_sym] = TaskEventGenerator.new(self, ev_model)
	    end
	    @bound_events = bound_events
        end

	attr_reader :model

	# Returns for how many seconds this task is running.  Returns nil if
	# the task is not running.
	def lifetime
	    if running?
		Time.now - history.first.time
	    end
	end

        # Returns when this task has been started
        def start_time
            if !history.empty?
                history.first.time
            end
        end

        # Returns when this task has finished
        def end_time
            if finished?
                history.last.time
            end
        end

        def create_fresh_copy
	    model.new(arguments.dup)
        end

	def initialize_copy(old) # :nodoc:
	    super

	    @name    = nil
	    @history = old.history.dup

	    @arguments = TaskArguments.new(self)
	    arguments.force_merge! old.arguments
	    arguments.instance_variable_set(:@task, self)

	    @instantiated_model_events = false

	    # Create all event generators
	    bound_events = Hash.new
	    model.each_event do |ev_symbol, ev_model|
                if old.has_event?(ev_symbol)
                    ev = old.event(ev_symbol).dup
                    ev.instance_variable_set(:@task, self)
                    bound_events[ev_symbol.to_sym] = ev
                end
	    end
	    @bound_events = bound_events
            @execute_handlers = old.execute_handlers.dup
            @poll_handlers = old.poll_handlers.dup
            if m = old.instance_variable_get(:@fullfilled_model)
                @fullfilled_model = m.dup
            end
	end

	def instantiate_model_event_relations
	    return if @instantiated_model_events
	    # Add the model-level signals to this instance
	    @instantiated_model_events = true
	    
	    model.all_signals.each do |generator, signalled_events|
	        next if signalled_events.empty?
	        generator = bound_events[generator]

	        for signalled in signalled_events
	            signalled = bound_events[signalled]
	            generator.signals signalled
	        end
	    end

	    model.all_forwardings.each do |generator, signalled_events|
		next if signalled_events.empty?
	        generator = bound_events[generator]

	        for signalled in signalled_events
	            signalled = bound_events[signalled]
	            generator.forward_to signalled
	        end
	    end

	    model.all_causal_links.each do |generator, signalled_events|
	        next if signalled_events.empty?
	        generator = bound_events[generator]

	        for signalled in signalled_events
	            signalled = bound_events[signalled]
	            generator.add_causal_link signalled
	        end
	    end

            # Add a link from internal_event to stop if stop is controllable
            if event(:stop).controlable?
                event(:internal_error).signals event(:stop)
            end

	    terminal_events, success_events, failure_events = update_terminal_flag

	    # WARN: the start event CAN be terminal: it can be a signal from
	    # :start to a terminal event
	    #
	    # Create the precedence relations between 'normal' events and the terminal events
            root_terminal_events = terminal_events.find_all do |ev|
                ev.symbol != :start && ev.root?(Roby::EventStructure::Precedence)
            end

            each_event do |ev|
                next if ev.symbol == :start
                if !ev.terminal?
                    if ev.root?(Roby::EventStructure::Precedence)
                        start_event.add_precedence(ev)
                    end
                    if ev.leaf?(Roby::EventStructure::Precedence)
                        for terminal in root_terminal_events
                            ev.add_precedence(terminal)
                        end
                    end
                end
            end
	end

	def plan=(new_plan) # :nodoc:
	    if plan != new_plan
                # Event though I don't like it, there is a special case here.
                #
                # Namely, if plan is nil and we are running, it most likely
                # means that we have been dup'ed. As it is a legal use, we have
                # to admit it.
                #
                # Note that PlanObject#plan= will catch the case of a removed
                # object that is being re-added in a plan.
		if plan 
                    if plan.include?(self)
                        raise ModelViolation.new, "#{self} still included in #{plan}, cannot change the plan to #{new_plan}"
                    elsif !kind_of?(Proxying) && self_owned? && running?
                        raise ModelViolation.new, "cannot change the plan of #{self} from #{plan} to #{new_plan} as the task is running"
                    end
                end
	    end

	    super

	    for _, ev in bound_events
		ev.plan = plan
	    end
	end

	# Roby::Task is an abstract model. See Models::Task#abstract
	abstract

        ## :method:abstract?
        #
        # If true, this instance is marked as abstract, i.e. as a placeholder
        # for future actions.
        #
        # By default, it takes the value of its model, i.e. through
        # model.abstract, set by calling abstract in a task model definition as
        # in
        #
        #   class MyModel < Roby::Task
        #     abstract
        #   end
        #
        # It can also be overriden on a per instance basis with
        #
        #   task.abstract = <value>
        #
        attr_predicate :abstract?, true
        
	# True if this task is executable. A task is not executable if it is
        # abstract or partially instanciated.
        #
        # See #abstract? and #partially_instanciated?
	def executable?
            if @executable == true
                true
            elsif @executable.nil?
                (!abstract? && !partially_instanciated? && super)
            end
        end

	# Returns true if this task's stop event is controlable
	def interruptible?; event(:stop).controlable? end
	# Set the executable flag. executable cannot be set to +false+ if the 
	# task is running, and cannot be set to true on a finished task.
	def executable=(flag)
	    return if flag == @executable
	    return unless self_owned?
	    if flag && !pending? 
		raise ModelViolation, "cannot set the executable flag of #{self} since it is not pending"
	    elsif !flag && running?
		raise ModelViolation, "cannot unset the executable flag of #{self} since it is running"
	    end
	    super
	end

        # Lists all arguments, that are set to be needed via the :argument 
        # syntax but are not set.
        #
        # This is needed for debugging purposes.
        def list_unset_arguments # :nodoc:
            actual_arguments =
                if arguments.static?
                    arguments
                else
                    arguments.evaluate_delayed_arguments
                end

            model.arguments.find_all do |name|
                !actual_arguments.has_key?(name)
            end
        end
	
        # True if all arguments defined by Task.argument on the task model are
        # either explicitely set or have a default value.
	def fully_instanciated?
            if arguments.static?
                @fully_instanciated ||= list_unset_arguments.empty?
            else
                list_unset_arguments.empty?
            end
	end

        # True if at least one argument required by the task model is not set.
        # See Task.argument.
	def partially_instanciated?; !fully_instanciated? end

        # True if this task has an event of the required model. The event model
        # can either be a event class or an event name.
        def has_event?(event_model)
	    bound_events.has_key?(event_model)
	end
        
        # True if this task is starting, i.e. if its start event is pending
        # (has been called, but is not emitted yet)
	def starting?; event(:start).pending? end
	# True if this task can be started
	def pending?; !failed_to_start? && !starting? && !started? &&
            (!engine || !engine.has_error_from?(self))
        end
        # True if this task is currently running (i.e. is has already started,
        # and is not finished)
        def running?; started? && !finished? end

	attr_predicate :started?, true
	attr_predicate :finished?, true
	attr_predicate :success?, true
        # True if the task is finishing, i.e. if a terminal event is pending.
        attr_predicate :finishing?, true

        # Call to force the value of {#reusable?} to false
        # @return [void]
        def do_not_reuse
            @reusable = false
        end

        # True if this task can be reused by some other parts in the plan
        def reusable?
            @reusable && !finished? && !finishing?
        end

        def failed_to_start?; !!@failed_to_start end

        def failed_to_start!(reason, time = Time.now)
            @failed_to_start = true
            @failed_to_start_time = time
            @failure_reason = reason
            plan.task_index.set_state(self, :failed?)

            each_event do |ev|
                ev.unreachable!(reason)
            end

            failed_to_start(reason)
        end

        # Hook called in failed_to_start! to announce that this task failed to
        # start
        def failed_to_start(reason); super if defined? super end

        # True if the +failed+ event of this task has been fired
	def failed?; failed_to_start? || (@success == false) end

        # Remove all relations in which +self+ or its event are involved
	def clear_relations
            each_event { |ev| ev.clear_relations }
	    super()
            self
	end

        def invalidated_terminal_flag?; !!@terminal_flag_invalid end
        def invalidate_terminal_flag; @terminal_flag_invalid = true end


        def do_terminal_flag_update(terminal_set, set, root)
            stack = [root]
            while !stack.empty?
                vertex = stack.shift
                for relation in [EventStructure::Signal, EventStructure::Forwarding]
                    for parent in vertex.parent_objects(relation)
                        next if !parent.respond_to?(:task) || parent.task != self
                        next if parent[vertex, relation]

                        if !terminal_set.include?(parent)
                            terminal_set  << parent
                            set   << parent if set
                            stack << parent
                        end
                    end
                end
            end
        end

	# Updates the terminal flag for all events in the task. An event is
	# terminal if the +stop+ event of the task will be called because this
	# event is.
	def update_terminal_flag # :nodoc:
            return if !@terminal_flag_invalid
	    return unless @instantiated_model_events

	    for _, ev in bound_events
		ev.terminal_flag = nil
	    end

            success_events, failure_events, terminal_events =
                [event(:success)].to_value_set, 
                [event(:failed)].to_value_set,
                [event(:stop), event(:success), event(:failed)].to_value_set

            do_terminal_flag_update(terminal_events, success_events, event(:success))
            do_terminal_flag_update(terminal_events, failure_events, event(:failed))
            do_terminal_flag_update(terminal_events, nil, event(:stop))

	    for ev in terminal_events
                if success_events.include?(ev)
                    ev.terminal_flag = :success
                elsif failure_events.include?(ev)
                    ev.terminal_flag = :failure
                else
                    ev.terminal_flag = true
                end
	    end
            @terminal_flag_invalid = false

            return terminal_events, success_events, failure_events
	end

        # Returns a list of Event objects, for all events that have been fired
        # by this task. The list is sorted by emission times.
	def history
	    history = []
	    each_event do |event|
		history += event.history
	    end

	    history.sort_by { |ev| ev.time }
	end

        # Returns the set of tasks directly related to this task, either because
        # of task relations or because of task events that are related to other
        # task events
	def related_tasks(result = nil)
	    result = related_objects(nil, result)
	    each_event do |ev|
		ev.related_tasks(result)
	    end

	    result
	end
        
        # Returns the set of events directly related to this task
	def related_events(result = nil)
	    each_event do |ev|
		result = ev.related_events(result)
	    end

	    result.reject { |ev| ev.respond_to?(:task) && ev.task == self }.
		to_value_set
	end
            
        # This method is called by TaskEventGenerator#fire just before the event handlers
        # and commands are called
        def emitting_event(event, context) # :nodoc:
	    if !executable?
		raise TaskNotExecutable.new(self), "trying to emit #{symbol} on #{self} but #{self} is not executable"
	    end

            if finished? && !event.terminal?
                raise EmissionFailed.new(nil, event),
		    "emit(#{event.symbol}, #{context}) called by #{plan.engine.propagation_sources.to_a} but the task has finished. Task has been terminated by #{event(:stop).history.first.sources}."
            elsif pending? && event.symbol != :start
                raise EmissionFailed.new(nil, event),
		    "emit(#{event.symbol}, #{context}) called by #{plan.engine.propagation_sources.to_a} but the task has never been started"
            elsif running? && event.symbol == :start
                raise EmissionFailed.new(nil, event),
		    "emit(#{event.symbol}, #{context}) called by #{plan.engine.propagation_sources.to_a} but the task is already running. Task has been started by #{event(:start).history.first.sources}."
            end

	    super if defined? super
        end

        # Hook called by TaskEventGenerator#fired when one of this task's events
        # has been fired.
        def fired_event(event)
	    update_task_status(event)
	    super if defined? super
        end
    
        # The most specialized event that caused this task to end
	attr_reader :terminal_event

        # The reason for which this task failed.
        #
        # It can either be an event or a LocalizedError object.
        #
        # If it is an event, it is the most specialized event whose emission
        # has been forwarded to :failed
        #
        # If it is a LocalizedError object, it is the exception that caused the
        # task failure.
        attr_reader :failure_reason

        # The time at which the task failed to start
        attr_reader :failed_to_start_time

        # The event that caused this task to fail. This is equivalent to taking
        # the first emitted element of
        #   task.event(:failed).last.task_sources
        #
        # It is only much more efficient
        attr_reader :failure_event
	
	# Call to update the task status because of +event+
	def update_task_status(event) # :nodoc:
	    if event.success?
		plan.task_index.add_state(self, :success?)
		self.success = true
	    elsif event.failure?
		plan.task_index.add_state(self, :failed?)
		self.success = false
                @failure_reason ||= event
                @failure_event  ||= event
            end

	    if event.terminal?
		@terminal_event ||= event
	    end
	    
	    if event.symbol == :start
		plan.task_index.set_state(self, :running?)
		self.started = true
		@executable = true
	    elsif event.symbol == :stop
		plan.task_index.remove_state(self, :running?)
                plan.task_index.add_state(self, :finished?)
		self.finished = true
                self.finishing = false
	        @executable = false

		each_event do |ev|
                    ev.unreachable!(terminal_event)
                end
	    end
	end
        
	# List of EventGenerator objects bound to this task
        attr_reader :bound_events

        # Emits +event_model+ in the given +context+. Event handlers are fired.
        # This is equivalent to
        #   event(event_model).emit(*context)
        #
        # @param [Symbol] event_model the event that should be fired
        # @param [Object] context the event context, i.e. payload data that is
        #   propagated along with the event itself
        # @return self
        def emit(event_model, *context)
            event(event_model).emit(*context)
            self
        end

        # Returns the TaskEventGenerator which describes the required event
        # model. +event_model+ can either be an event name or an Event class.
        def event(event_model)
	    unless event = bound_events[event_model]
		event_model = self.event_model(event_model)
		unless event = bound_events[event_model.symbol]
		    raise "cannot find #{event_model.symbol.inspect} in the set of bound events in #{self}. Known events are #{bound_events}."
		end
	    end
	    event
        end

        # Registers an event handler for the given event.
        #
        # @overload on(event_name, options = Hash.new, &handler)
        #   @param [Symbol] event_model the generator for which this handler should be registered
        #   @yield [event] the event handler
        #   @yieldparam [TaskEvent] event the emitted event that caused this
        #     handler to be called
        #   @return self
        #
        # @overload on(event_name, task, target_events, &handler)
        #   @deprecated register the handler with #on and the signal with #signals
        def on(event_model, options = Hash.new, target_event = nil, &user_handler)
            if !options.kind_of?(Hash)
                Roby.error_deprecated "on(event_name, task, target_events) has been replaced by #signals"
            elsif !user_handler
                raise ArgumentError, "you must provide an event handler"
            end

            if user_handler
                generator = event(event_model)
                generator.on(options, &user_handler)
            end
            self
        end

        # Creates a signal between task events.
        #
        # Signals specify that a target event's command should be called
        # whenever a source event is emitted. To emit target events (i.e. not
        # calling the event's commands), use #forward_to
        #
        # Optionally, a delay can be added to the signal. See
        # EventGenerator#signals for more information on the available delay
        # options
        #
        # @overload signals(source_event, dest_task, dest_event)
        #   @param [Symbol] source_event the source event on self
        #   @param [Task] dest_task the target task owning the target event
        #   @param [Symbol] dest_event the target event on dest_task
        #   @return self
        #
        #   Sets up a signal between source_event on self and dest_event on
        #   dest_task.
        #
        # @overload signals(source_event, dest_task, dest_event, delay_options)
        #   @param [Symbol] source_event the source event on self
        #   @param [Task] dest_task the target task owning the target event
        #   @param [Symbol] dest_event the target event on dest_task
        #   @return self
        #
        #   Sets up a signal between source_event on self and dest_event on
        #   dest_task, with delay options. See EventGenerator#signals for more
        #   information on the available options
        #
        # @overload signals(source_event, dest_task)
        #   @deprecated you must always specify the target event
        #
        def signals(event_model, to, *to_task_events)
            generator = event(event_model)
            if Hash === to_task_events.last
                delay = to_task_events.pop
            end
	    to_events = case to
			when Task
			    if to_task_events.empty?
                                Roby.warn_deprecated "signals(event_name, target_task) is deprecated. You must now always specify the target event name"
				[to.event(generator.symbol)]
			    else
				to_task_events.map { |ev_model| to.event(ev_model) }
			    end
			when EventGenerator then [to]
			else []
			end

            to_events.push delay if delay
            generator.signals(*to_events)
            self
        end

        # @deprecated renamed to #forward_to for consistency reasons with
        #   EventGenerator
	def forward(name, to, *to_task_events)
            Roby.warn_deprecated "Task#forward has been renamed into Task#forward_to"
            if to_task_events.empty?
                Roby.warn_deprecated "the Task#forward(event_name, target_task) form is deprecated. Use Task#forward_to and specify the target event name"
            end

            forward_to(name, to, *to_task_events)
        end

        # Fowards an event to another event
        #
        # Forwarding an event means that the target event should be emitted
        # whenever the source event is emitted. To call the target event command
        # instead,use #signals
        #
        # Optionally, a delay can be added to the forwarding. See
        # EventGenerator#signals for more information on the available delay
        # options
        #
        # @overload forward_to(source_event, dest_task, dest_event)
        #   @param [Symbol] source_event the source event on self
        #   @param [Task] dest_task the target task owning the target event
        #   @param [Symbol] dest_event the target event on dest_task
        #   @return self
        #
        # @overload forward_to(source_event, dest_task, dest_event, delay_options)
        #   @param [Symbol] source_event the source event on self
        #   @param [Task] dest_task the target task owning the target event
        #   @param [Symbol] dest_event the target event on dest_task
        #   @return self
        #
        # @overload forward_to(source_event, dest_task)
        #   @deprecated you must always specify the target event
        #
	def forward_to(name, to, *to_task_events)
            generator = event(name)
            if Hash === to_task_events.last
                delay = to_task_events.pop
            end

	    to_events = if to.respond_to?(:event)
			    if to_task_events.empty?
                                Roby.warn_deprecated "forward_to(event_name, target_task) is deprecated. You must now always specify the target event name"
				[to.event(generator.symbol)]
                            else
                                to_task_events.map { |ev| to.event(ev) }
                            end
			elsif to.kind_of?(EventGenerator)
			    [to]
			else
			    raise ArgumentError, "expected Task or EventGenerator, got #{to}(#{to.class}: #{to.class.ancestors})"
			end

	    to_events.each do |ev|
		generator.forward_to ev, delay
	    end
	end

	attr_accessor :calling_event

	def method_missing(name, *args, &block) # :nodoc:
	    if calling_event && calling_event.respond_to?(name)
		calling_event.send(name, *args, &block)
	    else
		super
	    end
	end

        # Iterates on all the events defined for this task
        #
        # @param [Boolean] only_wrapped For consistency with transaction
        #   proxies. Should not be used in user code.
        # @yield [generator]
        # @yieldparam [TaskEventGenerator] generator the generators that are
        #   tied to this task
        # @return self
        def each_event(only_wrapped = true)
            if !block_given?
                return enum_for(:each_event, only_wrapped)
            end

	    for _, ev in bound_events
		yield(ev)
	    end
            self
        end
	alias :each_plan_child :each_event

        # Returns the set of terminal events this task has. A terminal event is
        # an event whose emission announces the end of the task. In most case,
        # it is an event which is forwarded directly on indirectly to +stop+.
	def terminal_events
	    bound_events.values.find_all { |ev| ev.terminal? }
	end

        # Get the event model for +event+
        def event_model(model); self.model.event_model(model) end

        def to_s # :nodoc:
	    s = name.dup + arguments.to_s
	    id = owners.map do |owner|
		next if owner == Roby::Distributed
		sibling = remote_siblings[owner]
		"#{sibling ? Object.address_from_id(sibling.ref).to_s(16) : 'nil'}@#{owner.remote_name}"
	    end
	    unless id.empty?
		s << "[" << id.join(",") << "]"
	    end
	    s
	end

	def pretty_print(pp, with_owners = true) # :nodoc:
	    pp.text "#{model.name}:0x#{self.address.to_s(16)}"
            if with_owners
                pp.breakable
                pp.nest(2) do
                    pp.text "  owners: "
                    pp.seplist(owners) { |r| pp.text r.to_s }
                    pp.breakable

                    pp.text "arguments: "
                    arguments.pretty_print(pp)
                end
            else
                pp.text " "
                arguments.pretty_print(pp)
            end
	end

        # True if this task is a null task. See NullTask.
        def null?; false end
        # Converts this object into a task object
	def to_task; self end
	
	event :start, :command => true

	# Define :stop before any other terminal event
	event :stop
	event :success, :terminal => true
	event :failed,  :terminal => true

	event :aborted
	forward :aborted => :failed

        event :internal_error
        # Forcefully mark internal_error as a failure event, even though it does
        # not forwards to failed
        class Task::InternalError; def failure?; true end end
        on :internal_error do |error|
            if error.context
                @failure_reason = error.context.first
            end
        end

        # The internal data for this task
	attr_reader :data
        # Sets the internal data value for this task. This calls the
        # #updated_data hook, and emits +updated_data+ if the task is running.
	def data=(value)
	    @data = value
	    updated_data
	    emit :updated_data if running?
	end
        # This hook is called whenever the internal data of this task is
        # updated.  See #data, #data= and the +updated_data+ event
	def updated_data
	    super if defined? super
	end
	event :updated_data, :command => false

	# Checks if +task+ is in the same execution state than +self+
	# Returns true if they are either both running or both pending
	def compatible_state?(task)
	    finished? || !(running? ^ task.running?)
	end

        # The set of instance-level execute blocks (InstanceHandler instances)
        attr_reader :execute_handlers

        # The set of instance-level poll blocks (InstanceHandler instances)
        attr_reader :poll_handlers

        # Add a block that is going to be executed once, either at the next
        # cycle if the task is already running, or when the task is started
        def execute(options = Hash.new, &block)
            default_on_replace = if abstract? then :copy else :drop end
            options = InstanceHandler.validate_options(options, :on_replace => default_on_replace)

            check_arity(block, 1)
            @execute_handlers << InstanceHandler.new(block, (options[:on_replace] == :copy))
            ensure_poll_handler_called
        end

        # Adds a new poll block on this instance
        def poll(options = Hash.new, &block)
            default_on_replace = if abstract? then :copy else :drop end
            options = InstanceHandler.validate_options(options, :on_replace => default_on_replace)
            
            check_arity(block, 1)
            @poll_handlers << InstanceHandler.new(block, (options[:on_replace] == :copy))
            ensure_poll_handler_called
        end

        def ensure_poll_handler_called
            if !transaction_proxy? && running?
                @poll_handler_id ||= engine.add_propagation_handler(:type => :external_events, &method(:do_poll))
            end
        end

        # Internal method used to register the poll blocks in the engine
        # execution cycle
        def do_poll(plan) # :nodoc:
            return unless self_owned?
            # Don't call if we are terminating
            return if finished?
            # Don't call if we already had an error in the poll block
            return if event(:internal_error).happened?

            begin
                while execute_block = @execute_handlers.pop
                    execute_block.block.call(self)
                end

                if respond_to?(:poll_handler)
                    poll_handler
                end
	        
                if respond_to?(:state_machine)
                   state_machine.do_poll(self)
                end

                @poll_handlers.each do |poll_block|
                    poll_block.block.call(self)
                end
            rescue LocalizedError => e
                Roby.log_pp(e, Roby.logger, :warn)
                emit :internal_error, e
            rescue Exception => e
                Roby.log_pp(e, Roby.logger, :warn)
                emit :internal_error, CodeError.new(e, self)
            end
        end

        on :start do |ev|
            engine = plan.engine

            do_poll(self.plan)

            # Register poll:
            #  - single class poll_handler add be class method Task#poll
            #  - additional instance poll_handler added by instance method poll
            #  - polling as defined in state of the state_machine, i.e. substates of running
            if respond_to?(:poll_handler) || !poll_handlers.empty? || respond_to?(:state_machine)
                @poll_handler_id = engine.add_propagation_handler(:type => :external_events, &method(:do_poll))
            end
        end

        on :stop do |ev|
            if @poll_handler_id
                plan.engine.remove_propagation_handler(@poll_handler_id)
            end
        end

	# The fullfills? predicate checks if this task can be used
	# to fullfill the need of the given +model+ and +arguments+
	# The default is to check if
	#   * the needed task model is an ancestor of this task
	#   * the task 
	#   * +args+ is included in the task arguments
	def fullfills?(models, args = nil)
            if !models.respond_to?(:each)
                models = [models]
            end

            models = models.inject([]) do |models, m|
                if !args && m.kind_of?(Task)
                    args = m.meaningful_arguments
                end

                if m.respond_to?(:each_fullfilled_model)
                    models.concat(m.each_fullfilled_model.to_a)
                else
                    models << m
                end
            end

	    self_model = self.model
	    self_args  = self.arguments

	    # Check the arguments that are required by the model
	    for tag in models
		if !self_model.has_ancestor?(tag)
		    return false
		end
	    end

            if args
                args.each do |key, name|
                    if self.arguments[key] != name
                        return false
                    end
                end
            end

	    true
	end

        # True if this model requires an argument named +key+ and that argument
        # is set
        def has_argument?(key)
            self.arguments.has_key?(key)
        end

        # True if +self+ can be used to replace +target+
        def can_replace?(target)
            fullfills?(*target.fullfilled_model)
        end

	def can_merge?(target)
            if defined?(super) && !super
                return
            end

            if finished? || target.finished?
                return false
            end

	    target_model = target.fullfilled_model
	    if !fullfills?(target_model.first)
		return false
	    end

	    target_model.last.each do |key, val|
		if arguments.set?(key) && arguments[key] != val
		    return false
		end
	    end
	    true
	end

        # "Simply" mark this task as terminated. This is meant to be used on
        # quarantined tasks in tests.
        #
        # Do not use this unless you really know what you are doing
        def forcefully_terminate
            update_task_status(event(:stop).new([]))
        end

	include ExceptionHandlingObject

        # Lists all exception handlers attached to this task
	def each_exception_handler(&iterator); model.each_exception_handler(&iterator) end

	# We can't add relations on objects we don't own
	def add_child_object(child, type, info)
	    unless read_write? && child.read_write?
	        raise OwnershipError, "cannot add a relation between tasks we don't own.  #{self} by #{owners.to_a} and #{child} is owned by #{child.owners.to_a}"
	    end

	    super
	end

        # This method is called during the commit process to 
	def commit_transaction
	    super if defined? super

	    arguments.dup.each do |key, value|
		if value.kind_of?(Roby::Transaction::Proxying)
		    arguments.update!(key, value.__getobj__)
		end
	    end
	end

        # Create a new task of the same model and with the same arguments
        # than this one. Insert this task in the plan and make it replace
        # the fresh one.
        #
        # See Plan#respawn
	def respawn
	    plan.respawn(self)
	end

        # Replaces, in the plan, the subplan generated by this plan object by
        # the one generated by +object+. In practice, it means that we transfer
        # all parent edges whose target is +self+ from the receiver to
        # +object+. It calls the various add/remove hooks defined in
        # DirectedRelationSupport.
	def replace_subplan_by(object)
	    super

	    # Compute the set of tasks that are in our subtree and not in
	    # object's *after* the replacement
	    tree = ValueSet.new
	    TaskStructure.each_root_relation do |rel|
		tree.merge generated_subgraph(rel)
                tree.merge object.generated_subgraph(rel)
	    end
            tree << self << object

	    changes = []
	    each_event do |event|
		next unless object.has_event?(event.symbol)
		changes.clear

		event.each_relation do |rel|
		    parents = []
		    event.each_parent_object(rel) do |parent|
			if !parent.respond_to?(:task) || !tree.include?(parent.task)
			    parents << parent << parent[event, rel]
			end
		    end
		    children = []
		    event.each_child_object(rel) do |child|
			if !child.respond_to?(:task) || !tree.include?(child.task)
			    children << child << event[child, rel]
			end
		    end
		    changes << rel << parents << children
		end

                target_event = object.event(event.symbol)
                event.initialize_replacement(target_event)
		event.apply_relation_changes(target_event, changes)
	    end
	end

        # Replaces +self+ by +object+ in all relations +self+ is part of, and
        # do the same for the task's event generators.
	def replace_by(object)
	    each_event do |event|
		event_name = event.symbol
		if object.has_event?(event_name)
		    event.replace_by object.event(event_name)
		end
	    end
	    super
	end

        def initialize_replacement(task)
            super

            execute_handlers.each do |handler|
                if handler.copy_on_replace?
                    task.execute(handler.as_options, &handler.block)
                end
            end

            poll_handlers.each do |handler|
                if handler.copy_on_replace?
                    task.poll(handler.as_options, &handler.block)
                end
            end
        end

        # Simulate that the given event is emitted
        def simulate
            simulation_task = self.model.simulation_model.new(arguments.to_hash)
            plan.force_replace(self, simulation_task)
            simulation_task
        end

        # Returns a PlanService object for this task
        def as_service
            @service ||= (plan.find_plan_service(self) || PlanService.new(self))
        end

        def when_finalized(options = Hash.new, &block)
            default = if abstract? then :copy else :drop end
            options, remaining = InstanceHandler.filter_options options, :on_replace => default
            super(options.merge(remaining), &block)
        end

        def command_or_handler_error(exception)
            if exception.originates_from?(self)
                error = exception.exception
                gen = exception.generator
                if gen.symbol == :start && !start_event.happened?
                    failed_to_start!(error)
                elsif pending?
                    pass_exception
                elsif !gen.terminal? && !event(:internal_error).happened?
                    emit :internal_error, error
                    if event(:stop).pending? || !event(:stop).controlable?
                        # In this case, we can't "just" stop the task. We have
                        # to inject +error+ in the exception handling and kill
                        # everything that depends on it.
                        add_error(TaskEmergencyTermination.new(self, error, false))
                    end
                else
                    # No nice way to isolate this error through the task
                    # interface, as we can't emergency stop it. Quarantine it
                    # and inject it in the normal exception propagation
                    # mechanisms.
                    Robot.fatal "putting #{self} in quarantine: #{self} failed to emit"
                    Robot.fatal "the error is:"
                    Roby.log_exception(error, Robot, :fatal)

                    plan.quarantine(self)
                    add_error(TaskEmergencyTermination.new(self, error, true))
                end
            else
                pass_exception
            end
        end

        on_exception(Roby::EmissionFailed) do |exception|
            command_or_handler_error(exception)
        end

        on_exception(Roby::CommandFailed) do |exception|
            command_or_handler_error(exception)
        end
    end

    # A special task model which does nothing and emits +success+
    # as soon as it is started.
    class NullTask < Task
        event :start, :command => true
        event :stop
        forward :start => :success

        # Always true. See Task#null?
        def null?; true end
    end

    # A virtual task is a task representation for a combination of two events.
    # This allows to combine two unrelated events, one being the +start+ event
    # of the virtual task and the other its success event.
    #
    # The task fails if the success event becomes unreachable.
    #
    # See VirtualTask.create
    class VirtualTask < Task
        # The start event
	attr_reader :start_event
        # The success event
	attr_accessor :success_event
        # Set the start event
	def start_event=(ev)
	    if !ev.controlable?
		raise ArgumentError, "the start event of a virtual task must be controlable"
	    end
	    @start_event = ev
	end

	event :start do |context|
	    event(:start).achieve_with(start_event)
	    start_event.call
	end
	on :start do |context|
	    success_event.forward_to_once event(:success)
	    success_event.if_unreachable(true) do
		emit :failed if executable?
	    end
	end

	terminates

        # Creates a new VirtualTask with the given start and success events
	def self.create(start, success)
	    task = VirtualTask.new
	    task.start_event = start
	    task.success_event = success

	    if start.respond_to?(:task)
		task.realized_by start.task
	    end
	    if success.respond_to?(:task)
		task.realized_by success.task
	    end

	    task
	end
    end

    unless defined? TaskStructure
	TaskStructure   = RelationSpace(Task)
        TaskStructure.default_graph_class = TaskRelationGraph
    end
end

