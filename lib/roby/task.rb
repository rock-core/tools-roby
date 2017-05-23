module Roby
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
    #           execution_engine.once { emit :other_event }
    #       end
    #   end
    #
    # define two controllable event. In the first case, the event is
    # immediately emitted, and in the second case it will be emitted at the
    # beginning of the next execution cycle.
    #
    # === Task relations
    #
    # Task relations are defined in the TaskStructure Relations::Space instance.
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
        
        # The accumulated history of this task
        #
        # This is the list of events that this task ever emitted, sorted by
        # emission time
        #
        # @return [Array<Event>]
        attr_reader :history

        # The list of coordination objects attached to this task
        #
        # @return [Array<Coordination::Base>]
        attr_reader :coordination_objects

	# The part of +arguments+ that is meaningful for this task model. I.e.
        # it returns the set of elements in the +arguments+ property that define
        # arguments listed in the task model
	def meaningful_arguments(task_model = self.model)
            task_model.meaningful_arguments(arguments)
	end

        # Called when the start event get called, to resolve the delayed
        # arguments (if there are any)
        def freeze_delayed_arguments
            if !arguments.static?
                result = Hash.new
                arguments.each do |key, value|
                    if TaskArguments.delayed_argument?(value)
                        catch(:no_value) do
                            result[key] = value.evaluate_delayed_argument(self)
                        end
                    end
                end
                assign_arguments(**result)
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
	# you want to know if it a mission for the local system, use Plan#mission_task?
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

        # Helper to assign multiple argument values at once
        #
        # It differs from calling assign_argument in a loop in two ways:
        # 
        # - it is common for subclasses to define a high-level argument that is,
        #   in the end, propagated to lower-level arguments. This method handles
        #   the fact that, when doing this, one will get parallel assignment of
        #   the high-level and low-level values during e.g. log replay which would
        #   fail in assign_arguments since arguments are single-assignation
        #
        # - assignation is all-or-nothing
        def assign_arguments(**arguments)
            initial_arguments = @arguments
            initial_set_arguments = initial_arguments.assigned_arguments
            current_arguments = initial_set_arguments.dup

            # First assign normal values
            arguments.each do |key, value|
                @arguments = TaskArguments.new(self)
                @arguments.merge!(initial_set_arguments)
                assign_argument(key, value)
                current_arguments.merge!(@arguments) do |k, v1, v2|
                    if v1 != v2
                        raise ArgumentError, "trying to override #{k}=#{v1} to #{v2}"
                    end
                    v1
                end
            end
            initial_arguments.merge!(current_arguments)

        ensure
            @arguments = initial_arguments
        end

        # Sets one of this task's arguments
        def assign_argument(key, value)
            key = key.to_sym
            if TaskArguments.delayed_argument?(value)
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

	
        # Create a new task object
        #
        # The task is initially added to a {TemplatePlan} object in which all of
        # the model's event relations are already instantiated.
        def initialize(plan: TemplatePlan.new, **arguments)
            @bound_events = Hash.new
            super(plan: plan)

	    @model   = self.class
            @abstract = @model.abstract?
            
            @failed_to_start = false
            @pending = true
            @started = false
            @running = false
            @starting = false
            @finished = false
            @finishing = false
            @success = nil
            @reusable = true
            @history = Array.new
            @coordination_objects = Array.new

	    @arguments = TaskArguments.new(self)
            assign_arguments(**arguments)
            # Now assign default values for the arguments that have not yet been
            # set
            model.arguments.each do |argname|
                next if @arguments.has_key?(argname)

                has_default, default = model.default_argument(argname)
                if has_default
                    assign_argument(argname, default)
                end
            end

            @poll_handlers = []
            @execute_handlers = []

	    initialize_events
            plan.register_task(self)
            template = self.model.template

            mappings = Hash.new
            template.events_by_name.each do |name, template_event|
                mappings[template_event] = bound_events[name]
            end
            template.copy_relation_graphs_to(plan, mappings)
            apply_terminal_flags(
                template.terminal_events.map(&mappings.method(:[])),
                template.success_events.map(&mappings.method(:[])),
                template.failure_events.map(&mappings.method(:[])))
            @terminal_flag_invalid = false

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
	    # Create all event generators
	    bound_events = Hash.new
	    model.each_event do |ev_symbol, ev_model|
                ev = TaskEventGenerator.new(self, ev_model)
                ev.plan = plan
		bound_events[ev_symbol.to_sym] = ev
	    end
	    @bound_events = bound_events
        end

        # @see (PlanObject#promise)
        # @raise PromiseInFinishedTask if attempting to create a promise on a
        #   task that is either finished, or failed to start
        def promise(description: "#{self}.promise", executor: promise_executor, &block)
            if failed_to_start?
                raise PromiseInFinishedTask, "attempting to create a promise on #{self} that has failed to start"
            elsif finished?
                raise PromiseInFinishedTask, "attempting to create a promise on #{self} that is finished"
            end
            super
        end

	# Returns for how many seconds this task is running.  Returns nil if
	# the task is not running.
        def lifetime
            if running?
                Time.now - start_time
            elsif finished?
                end_time - start_time
            end
        end

        # Returns when this task has been started
        def start_time
            if ev = start_event.last
                ev.time
            end
        end

        # Returns when this task has finished
        def end_time
            if ev = stop_event.last
                ev.time
            end
        end

        # The last event emitted by this task
        #
        # @return [TaskEvent,nil]
        def last_event
            history.last
        end

        def create_fresh_copy
	    model.new(arguments.dup)
        end

	def initialize_copy(old) # :nodoc:
	    super

	    @name    = nil

	    @arguments = TaskArguments.new(self)
	    arguments.force_merge! old.arguments
	    arguments.instance_variable_set(:@task, self)

	    @instantiated_model_events = false

	    # Create all event generators
            @bound_events = Hash.new
            @execute_handlers = old.execute_handlers.dup
            @poll_handlers = old.poll_handlers.dup
            if m = old.instance_variable_get(:@fullfilled_model)
                @fullfilled_model = m.dup
            end
	end

	def plan=(new_plan) # :nodoc:
	    super

            @relation_graphs =
                if plan then plan.task_relation_graphs
                end
            for ev in bound_events.each_value
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
        # @see abstract? partially_instanciated?
	def executable?
            if @executable == true
                true
            elsif @executable.nil?
                (!abstract? && !partially_instanciated? && super)
            end
        end

	# Returns true if this task's stop event is controlable
	def interruptible?; stop_event.controlable? end
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
	attr_predicate :starting?, true
	# True if this task can be started
        attr_predicate :pending?, true
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
            plan && @reusable && !quarantined? && !garbage? && !failed_to_start? && !finished? && !finishing?
        end

        def garbage!
            bound_events.each_value(&:garbage!)
            super
        end

        # @!method quarantined?
        #
        # Whether this task has been quarantined
        attr_predicate :quarantined?

        # Mark the task as quarantined
        #
        # Once set it cannot be unset
        def quarantined!
            @quarantined = true
        end

        def failed_to_start?; @failed_to_start end

        def mark_failed_to_start(reason, time)
            if failed_to_start?
                return
            elsif !pending? && !starting?
                raise Roby::InternalError, "#{self} is neither pending nor starting, cannot mark as failed_to_start!"
            end
            @failed_to_start = true
            @failed_to_start_time = time
            @failure_reason = reason
            @pending = false
            @starting = false
            plan.task_index.set_state(self, :failed?)
        end

        def failed_to_start!(reason, time = Time.now)
            mark_failed_to_start(reason, time)
            each_event do |ev|
                ev.unreachable!(reason)
            end
            execution_engine.log(:task_failed_to_start, self, reason)
        end

        # True if the +failed+ event of this task has been fired
	def failed?; failed_to_start? || (@success == false) end

        # Clear relations events of this task have with events outside the task
        def clear_events_external_relations(remove_strong: true)
            removed = false
            task_events = bound_events.values
            each_event do |event|
                for rel in event.sorted_relations
                    graph = plan.event_relation_graph_for(rel)
                    next if !remove_strong && graph.strong?

                    to_remove = Array.new
                    graph.each_in_neighbour(event) do |neighbour|
                        if !task_events.include?(neighbour)
                            to_remove << neighbour << event
                        end
                    end
                    graph.each_out_neighbour(event) do |neighbour|
                        if !task_events.include?(neighbour)
                            to_remove << event << neighbour
                        end
                    end
                    to_remove.each_slice(2) do |from, to|
                        graph.remove_edge(from, to)
                    end
                    removed ||= !to_remove.empty?
                end
            end
            removed
        end

        # Remove all relations in which +self+ or its event are involved
        #
        # @param [Boolean] remove_internal if true, remove in-task relations between
        #   events
        # @param [Boolean] remove_strong if true, remove strong relations as well
	def clear_relations(remove_internal: false, remove_strong: true)
            modified_plan = false
            if remove_internal
                each_event do |ev|
                    if ev.clear_relations(remove_strong: remove_strong)
                        modified_plan = true
                    end
                end
            else
                modified_plan = clear_events_external_relations(remove_strong: remove_strong)
            end
	    super(remove_strong: remove_strong) || modified_plan
	end

        def invalidated_terminal_flag?; !!@terminal_flag_invalid end
        def invalidate_terminal_flag; @terminal_flag_invalid = true end

	# Updates the terminal flag for all events in the task. An event is
	# terminal if the +stop+ event of the task will be called because this
	# event is.
	def update_terminal_flag # :nodoc:
            return if !invalidated_terminal_flag?
            terminal_events, success_events, failure_events =
                self.model.compute_terminal_events(bound_events)
            apply_terminal_flags(terminal_events, success_events, failure_events)
            @terminal_flag_invalid = false
            return terminal_events, success_events, failure_events
        end

        def apply_terminal_flags(terminal_events, success_events, failure_events)
            for ev in bound_events.each_value
		ev.terminal_flag = nil
                if terminal_events.include?(ev)
                    if success_events.include?(ev)
                        ev.terminal_flag = :success
                    elsif failure_events.include?(ev)
                        ev.terminal_flag = :failure
                    else
                        ev.terminal_flag = true
                    end
                end
	    end
	end

        # Returns a list of Event objects, for all events that have been fired
        # by this task. The list is sorted by emission times.
	attr_reader :history

        # Returns the set of tasks directly related to this task, either because
        # of task relations or because of task events that are related to other
        # task events
        def related_tasks(result = Set.new)
	    result = related_objects(nil, result)
	    each_event do |ev|
		ev.related_tasks(result)
	    end

	    result
	end
        
        # Returns the set of events directly related to this task
        def related_events(result = Set.new)
	    each_event do |ev|
		ev.related_events(result)
	    end

	    result.reject { |ev| ev.respond_to?(:task) && ev.task == self }.
		to_set
	end
            
        # This method is called by TaskEventGenerator#fire just before the event handlers
        # and commands are called
        def check_emission_validity(event) # :nodoc:
            if finished? && !event.terminal?
                EmissionRejected.new(event).
                    exception("#{self}.emit(#{event.symbol}) called by #{execution_engine.propagation_sources.to_a} but the task has finished. Task has been terminated by #{stop_event.last.sources.to_a}.")
            elsif pending? && event.symbol != :start
                EmissionRejected.new(event).
                    exception("#{self}.emit(#{event.symbol}) called by #{execution_engine.propagation_sources.to_a} but the task has never been started")
            elsif running? && event.symbol == :start
                EmissionRejected.new(event).
                    exception("#{self}.emit(#{event.symbol}) called by #{execution_engine.propagation_sources.to_a} but the task is already running. Task has been started by #{start_event.last.sources.to_a}.")
            end
        end

        # Hook called by TaskEventGenerator#fired when one of this task's events
        # has been fired.
        def fired_event(event)
            history << event
	    update_task_status(event)
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
	    if event.symbol == :start
		plan.task_index.set_state(self, :running?)
                @starting = false
                @pending  = false
		@started  = true
                @running  = true
		@executable = true
            end

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
	    
	    if event.symbol == :stop
		plan.task_index.remove_state(self, :running?)
                @running    = false
                plan.task_index.add_state(self, :finished?)
                @finishing  = false
		@finished   = true
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
            Roby.warn_deprecated "Roby::Task#emit(event_name) is deprecated, use EventGenerator#emit (e.g. task.start_event.emit or task.event(:start).emit)"
            event(event_model).emit(*context)
            self
        end

        def find_event(name)
            bound_events[name] ||
                bound_events[event_model(name).symbol]
        end

        # Returns the TaskEventGenerator which describes the required event
        # model. +event_model+ can either be an event name or an Event class.
        def event(event_model)
            if event = find_event(event_model)
                event
            else
                raise ArgumentError, "cannot find #{event_model} in the set of bound events in #{self}. Known events are #{bound_events}."
            end
        end

        # Registers an event handler for the given event.
        #
        # @param [Symbol] event_model the generator for which this handler should be registered
        # @yield [event] the event handler
        # @yieldparam [TaskEvent] event the emitted event that caused this
        #   handler to be called
        # @return self
        def on(event_model, options = Hash.new, &user_handler)
            Roby.warn_deprecated "Task#on is deprecated, use EventGenerator#on instead (e.g. #{event_model}_event.signals other_event)"
            event(event_model).on(options, &user_handler)
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
        def signals(event_model, to, *to_task_events)
            Roby.warn_deprecated "Task#signals is deprecated, use EventGenerator#signal instead (e.g. #{event_model}_event.signals other_event)"

            generator = event(event_model)
            if Hash === to_task_events.last
                delay = to_task_events.pop
            end
	    to_events = case to
			when Task
                            to_task_events.map { |ev_model| to.event(ev_model) }
			when EventGenerator then [to]
			else
			    raise ArgumentError, "expected Task or EventGenerator, got #{to}(#{to.class}: #{to.class.ancestors})"
			end

            to_events.each do |event|
                generator.signals event, delay
            end
            self
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
	def forward_to(event_model, to, *to_task_events)
            Roby.warn_deprecated "Task#forward_to is deprecated, use EventGenerator#forward_to instead (e.g. #{event_model}_event.forward_to other_event)"

            generator = event(event_model)
            if Hash === to_task_events.last
                delay = to_task_events.pop
            end
	    to_events = case
                        when Task
                            to_task_events.map { |ev| to.event(ev) }
                        when EventGenerator then [to]
			else
			    raise ArgumentError, "expected Task or EventGenerator, got #{to}(#{to.class}: #{to.class.ancestors})"
			end

	    to_events.each do |ev|
		generator.forward_to ev, delay
	    end
	end

	attr_accessor :calling_event

        def respond_to_missing?(m, include_private)
            has_through_method_missing?(m) || super
        end

	def method_missing(name, *args, &block) # :nodoc:
            if found = find_through_method_missing(name, args)
                found
	    elsif calling_event && calling_event.respond_to?(name)
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

            for ev in bound_events.each_value
		yield(ev)
	    end
            self
        end
	alias :each_plan_child :each_event

        # Returns the set of terminal events this task has. A terminal event is
        # an event whose emission announces the end of the task. In most case,
        # it is an event which is forwarded directly on indirectly to +stop+.
	def terminal_events
	    bound_events.each_value.find_all { |ev| ev.terminal? }
	end

        # Get the event model for +event+
        def event_model(model); self.model.event_model(model) end

        def to_s # :nodoc:
            s = "#{name}<id:#{droby_id.id}>(#{arguments})"
	    id = owners.map do |owner|
                next if plan && (owner == plan.local_owner)
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
                pp.nest(2) do
                    pp.breakable
                    pp.text "owners: "
                    pp.nest(2) do
                        pp.seplist(owners) { |r| pp.text r.to_s }
                    end
                end
            end
            pp.nest(2) do
                pp.breakable
                pp.text "arguments: "
                if !arguments.empty?
                    pp.nest(2) do
                        pp.breakable
                        arguments.pretty_print(pp)
                    end
                end
            end
	end

        # True if this task is a null task. See NullTask.
        def null?; false end
        # Converts this object into a task object
	def to_task; self end
	
        # Event emitted when the task is started
        #
        # It is controlable by default, its command simply emitting the start
        # event
	event :start, command: true

        # Event emitted when the task has stopped
        #
        # It is not controlable by default. If the task can be stopped without
        # any specific action, call {Models::Task#terminates} on the task model. If it
        # needs specific actions, define a controlable failed event and call
        # {Models::Task#interruptible}
        #
        # @example task with simple termination
        #   class MyTask < Roby::Task
        #     terminates
        #   end
        #
        # @example task with complex termination
        #   class Mytask < Roby::Task
        #     event :failed do
        #       # Terminate the underlying process
        #     end
        #     interruptible
        #   end
	event :stop

        # Event emitted when the task has successfully finished
        #
        # It is obviously forwarded to {#stop_event}
	event :success, terminal: true

        # Event emitted when the task has finished without performing its duty
        #
        # It is obviously forwarded to {#stop_event}
	event :failed,  terminal: true

        # Event emitted when the task's underlying {#execution_agent} finished
        # while the task was running
        #
        # It is obviously forwarded to {#failed_event}
	event :aborted
	forward aborted: :failed

        # Event emitted when a task internal code block ({Models::Task#on} handler,
        # {Models::Task#poll} block) raised an exception
        #
        # It signals {#stop_event} if {#stop_event} is controlable
        event :internal_error

        class InternalError
            # Mark the InternalError event as a failure event, even if it is not
            # forwarded to the stop event at the model level
            def failure?
                true
            end
        end

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
	end
	event :updated_data, command: false

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
            options = InstanceHandler.validate_options(options, on_replace: default_on_replace)

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
            options = InstanceHandler.validate_options(options, on_replace: default_on_replace)
            
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
                @poll_handler_id ||= execution_engine.add_propagation_handler(description: "poll block for #{self}", type: :external_events, &method(:do_poll))
            end
        end

        # Internal method used to register the poll blocks in the engine
        # execution cycle
        def do_poll(plan) # :nodoc:
            return unless self_owned?
            # Don't call if we are terminating
            return if finished?
            # Don't call if we already had an error in the poll block
            return if event(:internal_error).emitted?

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
                execution_engine.add_error(e)
            rescue Exception => e
                execution_engine.add_error(CodeError.new(e, self))
            end
        end

        on :start do |ev|
            engine = execution_engine

            # Register poll:
            #  - single class poll_handler add be class method Task#poll
            #  - additional instance poll_handler added by instance method poll
            #  - polling as defined in state of the state_machine, i.e. substates of running
            if respond_to?(:poll_handler) || !poll_handlers.empty? || state_machine
                @poll_handler_id = engine.add_propagation_handler(description: "poll block of #{self}", type: :external_events, &method(:do_poll))
            end
        end

        on :stop do |ev|
            if @poll_handler_id
                execution_engine.remove_propagation_handler(@poll_handler_id)
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
            stop_event.on do |event|
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

            target.arguments.each_assigned_argument do |key, val|
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
            return if !plan

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
	    super

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

        def compute_subplan_replacement_operation(object)
            edges, edges_candidates = [], []
            subplan_tasks = Set[self, object]
            parent_tasks  = Set.new
            plan.each_task_relation_graph do |g|
                next if g.strong?
                rel = g.class

                each_in_neighbour_merged(rel, intrusive: true) do |parent|
                    parent_tasks << parent
                    edges << [g, parent, self, parent, object]
                end
                object.each_in_neighbour_merged(rel, intrusive: true) do |parent|
                    parent_tasks << parent
                end

                if g.weak?
                    each_out_neighbour_merged(rel, intrusive: true) do |child|
                        edges_candidates << [child, [g, self, child, object, child]]
                    end
                else
                    object.each_out_neighbour_merged(rel, intrusive: true) do |child|
                        subplan_tasks << child
                    end
                    each_out_neighbour_merged(rel, intrusive: true) do |child|
                        subplan_tasks << child
                    end
                end
            end

            plan.each_event_relation_graph do |g|
                next if g.strong?
                rel = g.class

                model.each_event do |_, event|
                    event = plan.each_object_in_transaction_stack(self).
                        find { |_, o| o.find_event(event.symbol) }.
                        last.event(event.symbol)
                    object_event = plan.each_object_in_transaction_stack(object).
                        find { |_, o| o.find_event(event.symbol) }.
                        last.event(event.symbol)

                    event.each_in_neighbour_merged(rel, intrusive: false) do |_, parent|
                        if parent.respond_to?(:task)
                            edges_candidates <<
                                [plan[parent.task], [g, parent, event, parent, object_event]]
                        end
                    end
                    event.each_out_neighbour_merged(rel, intrusive: false) do |_, child|
                        if child.respond_to?(:task)
                            edges_candidates <<
                                [plan[child.task], [g, event, child, object_event, child]]
                        end
                    end
                end
            end

            edges_candidates.each do |reference_task, op|
                if subplan_tasks.include?(reference_task)
                    next
                elsif parent_tasks.include?(reference_task)
                    edges << op
                elsif plan.in_useful_subplan?(self, reference_task) || plan.in_useful_subplan?(object, reference_task)
                    subplan_tasks << reference_task
                else
                    edges << op
                end
            end

            edges = edges.map do |g, removed_parent, removed_child, added_parent, added_child|
                [g, plan[removed_parent], plan[removed_child], plan[added_parent], plan[added_child]]
            end
            edges
        end

        def apply_replacement_operations(edges)
            edges.each do |g, removed_parent, removed_child, added_parent, added_child|
                info = g.edge_info(removed_parent, removed_child)
                g.add_relation(plan[added_parent], plan[added_child], info)
            end
            edges.each do |g, removed_parent, removed_child, added_parent, added_child|
                if !g.copy_on_replace?
                    g.remove_relation(plan[removed_parent], plan[removed_child])
                end
            end
        end

        # Replaces, in the plan, the subplan generated by this plan object by
        # the one generated by +object+. In practice, it means that we transfer
        # all parent edges whose target is +self+ from the receiver to
        # +object+. It calls the various add/remove hooks defined in
        # {DirectedRelationSupport}.
        #
        # Relations to free events are not copied during replacement
	def replace_subplan_by(object)
            edges = compute_subplan_replacement_operation(object)
            apply_replacement_operations(edges)

            initialize_replacement(object)
            each_event do |event|
                event.initialize_replacement(object.event(event.symbol))
            end
	end

        def compute_object_replacement_operation(object)
            edges = []
            plan.each_task_relation_graph do |g|
                next if g.strong?

                g.each_in_neighbour(self) do |parent|
                    if parent != object
                        edges << [g, parent, self, parent, object]
                    end
                end
                g.each_out_neighbour(self) do |child|
                    if object != child
                        edges << [g, self, child, object, child]
                    end
                end
            end

            plan.each_event_relation_graph do |g|
                next if g.strong?

                each_event do |event|
                    object_event = nil
                    g.each_in_neighbour(event) do |parent|
                        if !parent.respond_to?(:task) || (parent.task != self && parent.task != object)
                            object_event ||= object.event(event.symbol)
                            edges << [g, parent, event, parent, object_event]
                        end
                    end
                    g.each_out_neighbour(event) do |child|
                        if !child.respond_to?(:task) || (child.task != self && child.task != object)
                            object_event ||= object.event(event.symbol)
                            edges << [g, event, child, object_event, child]
                        end
                    end
                end
            end
            edges
        end

        # Replaces +self+ by +object+ in all relations +self+ is part of, and
        # do the same for the task's event generators.
	def replace_by(object)
            event_mappings = Hash.new
            event_resolver = ->(e) { object.event(e.symbol) }
            each_event do |ev|
                event_mappings[ev] = [nil, event_resolver]
            end
            object.each_event do |ev|
                event_mappings[ev] = nil
            end
            plan.replace_subplan(Hash[self => object, object => nil], event_mappings)

            initialize_replacement(object)
            each_event do |event|
                event.initialize_replacement(nil) { object.event(event.symbol) }
            end
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
            options, remaining = InstanceHandler.filter_options options, on_replace: default
            super(options.merge(remaining), &block)
        end

        def internal_error_handler(exception)
            if !exception.originates_from?(self)
                return pass_exception
            end

            gen = exception.generator
            error = exception.exception
            if (gen == start_event) && !gen.emitted?
                if !failed_to_start?
                    failed_to_start!(error)
                end
            elsif !running?
                pass_exception
            elsif (!gen || !gen.terminal?) && !internal_error_event.emitted?
                internal_error_event.emit(error)
                if stop_event.pending? || !stop_event.controlable?
                    # In this case, we can't "just" stop the task. We have
                    # to inject +error+ in the exception handling and kill
                    # everything that depends on it.
                    add_error(TaskEmergencyTermination.new(self, error, false))
                end
            else
                if execution_engine.display_exceptions?
                    # No nice way to isolate this error through the task
                    # interface, as we can't emergency stop it. Quarantine it
                    # and inject it in the normal exception propagation
                    # mechanisms.
                    execution_engine.fatal "putting #{self} in quarantine: #{self} failed to emit"
                    execution_engine.fatal "the error is:"
                    Roby.log_exception_with_backtrace(error, execution_engine, :fatal)
                end

                plan.quarantine_task(self)
                add_error(TaskEmergencyTermination.new(self, error, true))
            end
        end

        on_exception(Roby::CodeError) do |exception|
            internal_error_handler(exception)
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

        def create_transaction_proxy(transaction)
            transaction.create_and_register_proxy_task(self)
        end

        def match
            self.class.match.with_instance(self)
        end

        # Enumerate the coordination objects currently attached to this task
        #
        # @yieldparam [Coordination::Base] object
        def each_coordination_object(&block)
            coordination_objects.each(&block)
        end

        # @api private
        #
        # Declare that a coordination object is attached to this task
        #
        # @param [Coordination::Base] object
        def add_coordination_object(object)
            coordination_objects.push(object)
        end

        # @api private
        #
        # Declare that a coordination object is no longer attached to this task
        #
        # @param [Coordination::Base] object
        def remove_coordination_object(object)
            coordination_objects.delete(object)
        end
    end


    unless defined? TaskStructure
	TaskStructure   = RelationSpace(Task)
        TaskStructure.default_graph_class = Relations::TaskRelationGraph
    end
end

