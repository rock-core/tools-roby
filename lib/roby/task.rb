module Roby
    TaskService = Models::TaskServiceModel.new
    TaskService.root = true

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
            return @name if @name
            name = "#{model.name || self.class.name}:0x#{address.to_s(16)}"
            if !frozen?
                @name = name
            end
            name
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
            if value.respond_to?(:evaluate_delayed_argument)
                @arguments[key] = value
            else
                if self.respond_to?("#{key}=")
                    self.send("#{key}=", value)
                end
                if @arguments.writable?(key, value)
                    # The accessor did not write the argument. That's alright
                    @arguments[key] = value
                end
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
            
            @failed_to_start = false
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

            if self.model.state_machine
                @state_machine = TaskStateMachine.new(self.model.state_machine)
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

        # Hook called when a new child is added to this task
        def added_child_object(child, relations, info)
            # We must call super first, as it calls
            # PlanObject#added_child_object: this hook will make sure that self
            # is added to child's plan if self is in no plan and child is.
            super if defined? super

            if plan
                plan.added_task_relation(self, child, relations)
            end
        end

        # Hook called when child is removed from this task
        def removed_child_object(child, relations)
            super if defined? super

            if plan
                plan.removed_task_relation(self, child, relations)
            end
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
		    "#{self}.emit(#{event.symbol}, #{context}) called by #{plan.engine.propagation_sources.to_a} but the task has finished. Task has been terminated by #{event(:stop).history.first.sources}."
            elsif pending? && event.symbol != :start
                raise EmissionFailed.new(nil, event),
		    "#{self}.emit(#{event.symbol}, #{context}) called by #{plan.engine.propagation_sources.to_a} but the task has never been started"
            elsif running? && event.symbol == :start
                raise EmissionFailed.new(nil, event),
		    "#{self}.emit(#{event.symbol}, #{context}) called by #{plan.engine.propagation_sources.to_a} but the task is already running. Task has been started by #{event(:start).history.first.sources}."
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

        def find_event(symbol)
            event(symbol)
        rescue ArgumentError
        end

        # Returns the TaskEventGenerator which describes the required event
        # model. +event_model+ can either be an event name or an Event class.
        def event(event_model)
	    unless event = bound_events[event_model]
		event_model = self.event_model(event_model)
		unless event = bound_events[event_model.symbol]
		    raise ArgumentError, "cannot find #{event_model.symbol.inspect} in the set of bound events in #{self}. Known events are #{bound_events}."
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
        #
        # @macro InstanceHandlerOptions
        # @yieldparam [Roby::Task] task the task on which the poll block is
        #   executed. It might be different than the one on which it has been
        #   added because of replacements.
        # @return [Object] an ID that can be used in {#remove_poll_handler}
        def poll(options = Hash.new, &block)
            default_on_replace = if abstract? then :copy else :drop end
            options = InstanceHandler.validate_options(options, :on_replace => default_on_replace)
            
            check_arity(block, 1)
            @poll_handlers << (handler = InstanceHandler.new(block, (options[:on_replace] == :copy)))
            ensure_poll_handler_called
            handler
        end

        # Remove a poll handler from this instance
        #
        # @param [Object] handler the ID returned by {#poll}
        # @return [void]
        def remove_poll_handler(handler)
            @poll_handlers.delete(handler)
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
	        
                if machine = state_machine
                   machine.do_poll(self)
                end

                @poll_handlers.each do |poll_block|
                    poll_block.block.call(self)
                end
            rescue LocalizedError => e
                Roby.log_exception(e, Roby.logger, :warn)
                emit :internal_error, e
            rescue Exception => e
                Roby.log_exception(e, Roby.logger, :warn)
                emit :internal_error, CodeError.new(e, self)
            end
        end

        on :start do |ev|
            engine = plan.engine

            # Register poll:
            #  - single class poll_handler add be class method Task#poll
            #  - additional instance poll_handler added by instance method poll
            #  - polling as defined in state of the state_machine, i.e. substates of running
            if respond_to?(:poll_handler) || !poll_handlers.empty? || state_machine
                @poll_handler_id = engine.add_propagation_handler(:type => :external_events, &method(:do_poll))
            end
        end

        on :stop do |ev|
            if @poll_handler_id
                plan.engine.remove_propagation_handler(@poll_handler_id)
            end
        end

        # Declares that this fault response table should be made active when
        # this task starts, and deactivated when it ends
        def use_fault_response_table(table_model, arguments = Hash.new)
            arguments = table_model.validate_arguments(arguments)

            table = nil
            execute do |task|
                table = task.plan.use_fault_response_table(table_model, arguments)
            end
            on :stop do |event|
                plan.remove_fault_response_table(table)
            end
        end

	# The fullfills? predicate checks if this task can be used
	# to fullfill the need of the given +model+ and +arguments+
	# The default is to check if
	#   * the needed task model is an ancestor of this task
	#   * the task 
	#   * +args+ is included in the task arguments
	def fullfills?(models, args = nil)
            if models.kind_of?(Roby::Task)
                args ||= models.meaningful_arguments
                models = models.model
            end
            if !model.fullfills?(models)
                return false
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
            self.arguments.set?(key)
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

            if !model.can_merge?(target.model)
                return false
            end

            target.arguments.each_static do |key, val|
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

        # Handles the given exception.
        #
        # In addition to the exception handlers provided by
        # {ExceptionHandlingObject}, it checks for repair tasks (as defined by
        # TaskStructure::ErrorHandling)
        #
        # @param [ExecutionException] e
        def handle_exception(e)
            tasks = find_all_matching_repair_tasks(e)
            return super if tasks.empty?
            if !tasks.any? { |t| t.running? }
                tasks.first.start!
            end
            true
        end

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
                if value.respond_to?(:transaction_proxy?) && value.transaction_proxy?
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

        # Returns an object that will allow to track this task's role in the
        # plan regardless of replacements
        #
        # The returning object will point to the replacing object when self is
        # replaced by something. In effect, it points to the task's role in the
        # plan instead of to the actual task itself.
        #
        # @return [PlanService]
        def as_service
            @service ||= (plan.find_plan_service(self) || PlanService.new(self))
        end

        def as_plan
            self
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

        # Creates a sequence where +self+ will be started first, and +task+ is
        # started if +self+ finished successfully. The returned value is an
        # instance of Sequence.
        #
        # Note that this operator always creates a new Sequence object, so
        #
        #   a + b + c + d
        #
        # will create 3 Sequence instances. If more than two tasks should be
        # organized in a sequence, one should instead use Sequence#<<:
        #   
        #   Sequence.new << a << b << c << d
        #  
        def +(task)
            # !!!! + is NOT commutative
            if task.null?
                self
            elsif self.null?
                task
            else
                Tasks::Sequence.new << self << task
            end
        end

        # Creates a parallel aggregation between +self+ and +task+. Both tasks
        # are started at the same time, and the returned instance finishes when
        # both tasks are finished. The returned value is an instance of
        # Parallel.
        #
        # Note that this operator always creates a new Parallel object, so
        #
        #   a | b | c | d
        #
        # will create three instances of Parallel. If more than two tasks should
        # be organized that way, one should instead use Parallel#<<:
        #   
        #   Parallel.new << a << b << c << d
        #  
        def |(task)
            if self.null?
                task
            elsif task.null?
                self
            else
                Tasks::Parallel.new << self << task
            end
        end

        def to_execution_exception
            ExecutionException.new(LocalizedError.new(self))
        end
    end


    unless defined? TaskStructure
	TaskStructure   = RelationSpace(Task)
        TaskStructure.default_graph_class = TaskRelationGraph
    end
end

