# frozen_string_literal: true

module Roby
    # In a plan, Task objects represent the system's activities.
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
    # @!macro InstanceHandlerOptions
    #   @option options [:copy,:drop] :on_replace defines the behaviour
    #      when this object gets replaced in the plan. If :copy is used,
    #      the handler is added to the replacing task and is also kept
    #      in the original task. If :drop, it is not copied (but is
    #      kept).
    class Task < PlanObject
        extend Models::Task
        provides TaskService

        # The task arguments
        #
        # @return [TaskArguments]
        attr_reader :arguments

        # The accumulated history of this task
        #
        # This is the list of events that this task ever emitted, sorted by
        # emission time (oldest first)
        #
        # @return [Array<Event>]
        attr_reader :history

        # The part of {#arguments} that is meaningful for this task model. I.e.
        # it returns the set of elements in {#arguments} that are listed in the
        # task model
        def meaningful_arguments(task_model = self.model)
            task_model.meaningful_arguments(arguments)
        end

        # @api private
        #
        # Evaluate delayed arguments, and replace in {#arguments} the ones that
        # currently have a value
        def freeze_delayed_arguments
            unless arguments.static?
                result = {}
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
        #
        # @return [String]
        def name
            return @name if @name

            name = model.name || self.class.name
            @name = name unless frozen?
            name
        end

        # Whether the task is a mission for its owners.
        #
        # If you want to know if it a mission for the local system, use
        # Plan#mission_task?. In non-distributed Roby, the two are identical
        attr_predicate :mission?, true

        def inspect
            state = if pending? then "pending"
                    elsif failed_to_start? then "failed to start"
                    elsif starting? then "starting"
                    elsif finishing? then "finishing"
                    elsif running? then "running"
                    else
                        "finished"
                    end
            "#<#{self} executable=#{executable?} state=#{state} plan=#{plan}>"
        end

        # @api private
        #
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

        # @api private
        #
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
        # @param [Plan] plan the plan this task should be added two. The default
        #   is to add it to its own TemplatePlan object
        # @param [Hash<Symbol,Object>] arguments assignation to task arguments
        def initialize(plan: TemplatePlan.new, **arguments)
            @bound_events = {}
            super(plan: plan)

            @model = self.class
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
            @history = []
            @coordination_objects = []

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

            mappings = {}
            template.events_by_name.each do |name, template_event|
                mappings[template_event] = bound_events[name]
            end
            template.copy_relation_graphs_to(plan, mappings)
            apply_terminal_flags(
                template.terminal_events.map(&mappings.method(:[])),
                template.success_events.map(&mappings.method(:[])),
                template.failure_events.map(&mappings.method(:[]))
            )
            @terminal_flag_invalid = false

            if self.model.state_machine
                @state_machine = TaskStateMachine.new(self.model.state_machine)
            end
        end

        # Retrieve the current state of the task
        #
        # Can be one of the core states: pending, failed_to_start, starting,
        # started, running, finishing, succeeded or failed
        #
        # If the task has a state machine defined with
        # {TaskStateHelper#refine_running_state}, the state
        # machine's current state will be returned in place of :running
        #
        # @return [Symbol]
        def current_state
            # Started and not finished
            # True, when task has never been started
            if pending?
                :pending
            elsif failed_to_start?
                :failed_to_start
            elsif starting?
                :starting
            # True, when terminal event is pending. Note that a finishing task
            # is running
            elsif finishing?
                :finishing
            elsif running?
                state_machine&.status_name || :running
            # Terminated with success or failure
            elsif success?
                :succeeded
            elsif failed?
                :failed
            elsif stop_event.emitted?
                :finished
            end
        end

        # Test if that current state corresponds to the provided state (symbol)
        #
        # @param [Symbol] state
        # @return [Boolean]
        def current_state?(state)
            state == current_state.to_sym
        end

        # Helper methods which creates all the necessary TaskEventGenerator
        # objects and stores them in the #bound_events map
        def initialize_events # :nodoc:
            # Create all event generators
            bound_events = {}
            model.each_event do |ev_symbol, ev_model|
                ev = TaskEventGenerator.new(self, ev_model)
                ev.plan = plan
                bound_events[ev_symbol.to_sym] = ev
            end
            @bound_events = bound_events
        end
        private :initialize_events

        # (see PlanObject#promise)
        #
        # @raise [PromiseInFinishedTask] if attempting to create a promise on a
        #   task that is either finished, or failed to start
        def promise(description: "#{self}.promise", executor: promise_executor, &block)
            if failed_to_start?
                raise PromiseInFinishedTask,
                      "attempting to create a promise on #{self} that has failed to start"
            elsif finished?
                raise PromiseInFinishedTask,
                      "attempting to create a promise on #{self} that is finished"
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
            model.new(**arguments.dup)
        end

        def initialize_copy(old) # :nodoc:
            super

            @name = nil

            @arguments = TaskArguments.new(self)
            arguments.force_merge! old.arguments
            arguments.instance_variable_set(:@task, self)

            @instantiated_model_events = false

            # Create all event generators
            @bound_events = {}
            @execute_handlers = old.execute_handlers.dup
            @poll_handlers = old.poll_handlers.dup
            if m = old.instance_variable_get(:@fullfilled_model)
                @fullfilled_model = m.dup
            end
        end

        def plan=(new_plan) # :nodoc:
            null = self.plan&.null_task_relation_graphs

            super

            @relation_graphs =
                plan&.task_relation_graphs || null || @relation_graphs
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
                !abstract? && !partially_instanciated? && super
            end
        end

        # Returns true if this task's stop event is controlable
        def interruptible?
            stop_event.controlable?
        end

        # Set the executable flag. executable cannot be set to +false+ if the
        # task is running, and cannot be set to true on a finished task.
        def executable=(flag)
            return if flag == @executable
            return unless self_owned?

            if flag && !pending?
                raise ModelViolation,
                      "cannot set the executable flag of #{self} since it is not pending"
            elsif !flag && running?
                raise ModelViolation,
                      "cannot unset the executable flag of #{self} since it is running"
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
        def partially_instanciated?
            !fully_instanciated?
        end

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
        def running?
            started? && !finished?
        end

        attr_predicate :started?, true
        attr_predicate :finished?, true
        attr_predicate :failed?, true
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
            plan && @reusable && !quarantined? && !garbage? && !failed_to_start? &&
                !finished? && !finishing?
        end

        def garbage!
            bound_events.each_value(&:garbage!)
            super
        end

        # Whether this task has been quarantined
        def quarantined?
            @quarantined
        end

        # The reason why the task is in quarantine
        #
        # If the quarantine was caused by an exception, this will return the
        # original exception
        #
        # @return [Exception,nil]
        attr_reader :quarantine_reason

        # Mark the task as quarantined
        #
        # Quarantined tasks are essentially tasks that are present in the plan, but
        # cannot be used because they are known to misbehave *and* themselves can't
        # be killed. The prime example is a task the system tried to stop but for
        # which the stop process failed.
        #
        # Once set it cannot be unset. The engine will generate a {QuarantinedTaskError}
        # error as long as there are tasks that depend on the task, to make sure that
        # anything that depend on it either stops using it, or is killed itself.
        #
        # @param [Exception,String,nil] reason if the quarantine was caused by an
        #   exception, pass it.there. It will be stored in {#quarantine_reason} and will
        #   be made available in the {Quarantine} error. Otherwise, pass a message
        #   that explains the quarantine
        def quarantined!(reason: nil)
            return if quarantined?

            @quarantined = true
            @quarantine_reason = reason

            fatal "#{self} entered quarantine: #{reason}"
            plan.register_quarantined_task(self)
        end

        def failed_to_start?
            @failed_to_start
        end

        def mark_failed_to_start(reason, time)
            if failed_to_start?
                return
            elsif !pending? && !starting?
                raise Roby::InternalError,
                      "#{self} is neither pending nor starting, "\
                      "cannot mark as failed_to_start!"
            end

            @failed_to_start = true
            @failed_to_start_time = time
            @failure_reason =
                if reason.kind_of?(LocalizedError) && reason.failed_task == self
                    reason
                else
                    FailedToStart.new(self, reason, time)
                end

            @pending = false
            @starting = false
            @failed   = true
            plan.task_index.set_state(self, :failed?)
        end

        # Declares that this task has failed to start
        #
        # @param [Object] reason the failure reason. Can either be an exception
        #   or an event
        #
        # {#failure_reason} will be set to {FailedToStart} with the given reason
        def failed_to_start!(reason, time = Time.now)
            mark_failed_to_start(reason, time)
            each_event do |ev|
                ev.unreachable!(reason)
            end
            execution_engine.log(:task_failed_to_start, self, reason)
        end

        # Clear relations events of this task have with events outside the task
        def clear_events_external_relations(remove_strong: true)
            removed = false
            task_events = bound_events.values
            each_event do |event|
                for rel in event.sorted_relations
                    graph = plan.event_relation_graph_for(rel)
                    next if !remove_strong && graph.strong?

                    parents = graph.each_in_neighbour(event).find_all do |neighbour|
                        !task_events.include?(neighbour)
                    end
                    children = graph.each_out_neighbour(event).find_all do |neighbour|
                        !task_events.include?(neighbour)
                    end

                    unless remove_strong
                        parents = filter_events_from_strongly_related_tasks(parents)
                        children = filter_events_from_strongly_related_tasks(children)
                    end

                    parents.each { |from| graph.remove_edge(from, event) }
                    children.each { |to| graph.remove_edge(event, to) }
                    removed ||= !parents.empty? || !children.empty?
                end
            end
            removed
        end

        def filter_events_from_strongly_related_tasks(events)
            return events if events.empty?

            strong_graphs = plan.each_relation_graph.find_all(&:strong?)
            events.find_all do |ev|
                next(true) unless ev.respond_to?(:task)

                task = ev.task
                strong_graphs.none? do |g|
                    g.has_edge?(self, task) || g.has_edge?(task, self)
                end
            end
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
                modified_plan =
                    clear_events_external_relations(remove_strong: remove_strong)
            end
            super(remove_strong: remove_strong) || modified_plan
        end

        def invalidated_terminal_flag?
            !!@terminal_flag_invalid
        end

        def invalidate_terminal_flag
            @terminal_flag_invalid = true
        end

        # Updates the terminal flag for all events in the task. An event is
        # terminal if the +stop+ event of the task will be called because this
        # event is.
        def update_terminal_flag # :nodoc:
            return unless invalidated_terminal_flag?

            terminal_events, success_events, failure_events =
                self.model.compute_terminal_events(bound_events)
            apply_terminal_flags(terminal_events, success_events, failure_events)
            @terminal_flag_invalid = false
            [terminal_events, success_events, failure_events]
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

            result.reject { |ev| ev.respond_to?(:task) && ev.task == self }
                .to_set
        end

        # This method is called by TaskEventGenerator#fire just before the event handlers
        # and commands are called
        def check_emission_validity(event) # :nodoc:
            if finished? && !event.terminal?
                EmissionRejected.new(event).exception(
                    "#{self}.emit(#{event.symbol}) called by "\
                    "#{execution_engine.propagation_sources.to_a} but the task "\
                    "has finished. Task has been terminated by "\
                    "#{stop_event.last.sources.to_a}."
                )
            elsif pending? && event.symbol != :start
                EmissionRejected.new(event).exception(
                    "#{self}.emit(#{event.symbol}) called by "\
                    "#{execution_engine.propagation_sources.to_a} but the task "\
                    "has never been started"
                )
            elsif running? && event.symbol == :start
                EmissionRejected.new(event).exception(
                    "#{self}.emit(#{event.symbol}) called by "\
                    "#{execution_engine.propagation_sources.to_a} but the task "\
                    "is already running. Task has been started by "\
                    "#{start_event.last.sources.to_a}."
                )
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
                @success = true
            elsif event.failure?
                plan.task_index.add_state(self, :failed?)
                @failed = true
                @failure_reason ||= event
                @failure_event  ||= event
            end

            @terminal_event ||= event if event.terminal?

            if event.symbol == :stop
                plan.task_index.remove_state(self, :running?)
                plan.task_index.add_state(self, :finished?)
                @running    = false
                @finishing  = false
                @finished   = true
                @executable = false
            end
            nil
        end

        # List of EventGenerator objects bound to this task
        attr_reader :bound_events

        # Returns the event generator by its name
        #
        # @param [Symbol] name the event name
        # @return [TaskEventGenerator,nil]
        def find_event(name)
            bound_events[name] ||
                bound_events[event_model(name).symbol]
        end

        # Returns the event generator by its name or model
        #
        # @param [Symbol] name the event name
        # @return [TaskEventGenerator,nil]
        # @raise [ArgumentError] if the event does not exist
        def event(event_model)
            unless (event = find_event(event_model))
                raise ArgumentError,
                      "cannot find #{event_model} in the set of bound events in "\
                      "#{self}. Known events are #{bound_events}."
            end

            event
        end

        # @!group Deprecated Event API

        # @deprecated use {TaskEventGenerator#emit} instead (e.g. task.start_event.emit)
        def emit(event_model, *context)
            Roby.warn_deprecated(
                "Roby::Task#emit(event_name) is deprecated, use EventGenerator#emit "\
                "(e.g. task.start_event.emit or task.event(:start).emit)"
            )
            event(event_model).emit(*context)
            self
        end

        # @deprecated use {TaskEventGenerator#on} on the event object, e.g.
        #   task.start_event.on { |event| ... }
        def on(event_model, options = {}, &user_handler)
            Roby.warn_deprecated(
                "Task#on is deprecated, use EventGenerator#on instead "\
                "(e.g. #{event_model}_event.signals other_event)"
            )
            event(event_model).on(options, &user_handler)
            self
        end

        # @deprecated use {TaskEventGenerator#signal} instead (e.g.
        # task.start_event.signal other_task.stop_event)
        def signals(event_model, to, *to_task_events)
            Roby.warn_deprecated(
                "Task#signals is deprecated, use EventGenerator#signal instead "\
                "(e.g. #{event_model}_event.signals other_event)"
            )

            generator = event(event_model)
            if Hash === to_task_events.last
                delay = to_task_events.pop
            end
            to_events =
                case to
                when Task
                    to_task_events.map { |ev_model| to.event(ev_model) }
                when EventGenerator
                    [to]
                else
                    raise ArgumentError,
                          "expected Task or EventGenerator, got #{to}(#{to.class}: "\
                          "#{to.class.ancestors})"
                end

            to_events.each do |event|
                generator.signals event, delay
            end
            self
        end

        # @deprecated use {TaskEventGenerator#forward_to} instead (e.g.
        # task.start_event.forward_to other_task.stop_event)
        def forward_to(event_model, to, *to_task_events)
            Roby.warn_deprecated(
                "Task#forward_to is deprecated, use EventGenerator#forward_to "\
                "instead (e.g. #{event_model}_event.forward_to other_event)"
            )

            generator = event(event_model)
            if Hash === to_task_events.last
                delay = to_task_events.pop
            end
            to_events =
                case to
                when Task
                    to_task_events.map { |ev| to.event(ev) }
                when EventGenerator
                    [to]
                else
                    raise ArgumentError,
                          "expected Task or EventGenerator, got #{to}(#{to.class}: "\
                          "#{to.class.ancestors})"
                end

            to_events.each do |ev|
                generator.forward_to ev, delay
            end
        end

        # @!endgroup Deprecated Event API

        include MetaRuby::DSLs::FindThroughMethodMissing

        # Iterates on all the events defined for this task
        #
        # @param [Boolean] only_wrapped For consistency with transaction
        #   proxies. Should not be used in user code.
        # @yield [generator]
        # @yieldparam [TaskEventGenerator] generator the generators that are
        #   tied to this task
        # @return self
        def each_event(only_wrapped = true)
            return enum_for(__method__, only_wrapped) unless block_given?

            for ev in bound_events.each_value
                yield(ev)
            end
            self
        end
        alias each_plan_child each_event

        # Returns this task's set of terminal events.
        #
        # A terminal event is an event whose emission announces the end of the
        # task. In most case, it is an event which is forwarded directly on
        # indirectly to +stop+.
        #
        # @return [Array<TaskEventGenerator>]
        def terminal_events
            bound_events.each_value.find_all(&:terminal?)
        end

        # (see Models::Task#event_model)
        def event_model(model)
            self.model.event_model(model)
        end

        def to_s # :nodoc:
            s = "#{name}<id:#{droby_id.id}>(#{arguments})".dup
            id = owners.map do |owner|
                next if plan && (owner == plan.local_owner)

                sibling = remote_siblings[owner]
                sibling_address =
                    if sibling
                        Object.address_from_id(sibling.ref).to_s(16)
                    else
                        "nil"
                    end

                "#{sibling_address}@#{owner.remote_name}"
            end
            s << "[" << id.join(",") << "]" unless id.empty?
            s
        end

        def pretty_print(pp, with_owners = true) # :nodoc:
            pp.text "#{model.name}<id:#{droby_id.id}>"
            if with_owners
                pp.nest(2) do
                    pp.breakable
                    if owners.empty?
                        pp.text "no owners"
                    else
                        pp.text "owners: "
                        pp.nest(2) do
                            pp.seplist(owners) { |r| pp.text r.to_s }
                        end
                    end
                end
            end

            pp.nest(2) do
                pp.breakable
                if arguments.empty?
                    pp.text "no arguments"
                else
                    pp.text "arguments:"
                    pp.nest(2) do
                        pp.breakable
                        arguments.pretty_print(pp)
                    end
                end
            end
        end

        # True if this task is a null task. See NullTask.
        def null?
            false
        end

        # Converts this object into a task object
        def to_task
            self
        end

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

        # Event emitted when the task's underlying
        # {TaskStructure::ExecutionAgent#execution_agent} finished
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
        #
        # @see data= updated_data updated_data_event
        attr_reader :data

        # Sets the internal data value for this task. This calls the
        # {#updated_data} hook, and emits {#updated_data_event} if the task is running.
        def data=(value)
            @data = value
            updated_data
            emit :updated_data if running?
        end

        # This hook is called whenever the internal data of this task is
        # updated.  See #data, #data= and the +updated_data+ event
        def updated_data; end
        event :updated_data, command: false

        # Checks if +task+ is in the same execution state than +self+
        # Returns true if they are either both running or both pending
        def compatible_state?(task)
            finished? || !(running? ^ task.running?)
        end

        # @api private
        #
        # The set of instance-level execute blocks
        #
        # @return [Array<InstanceHandler>]
        attr_reader :execute_handlers

        # @api private
        #
        # The set of instance-level poll blocks
        #
        # @return [Array<InstanceHandler>]
        attr_reader :poll_handlers

        # Add a block that is going to be executed once, either at the next
        # cycle if the task is already running, or when the task is started
        #
        # @macro InstanceHandlerOptions
        # @return [void]
        def execute(options = {}, &block)
            default_on_replace = abstract? ? :copy : :drop
            options = InstanceHandler.validate_options(
                options, on_replace: default_on_replace
            )

            check_arity(block, 1)
            @execute_handlers <<
                InstanceHandler.new(block, (options[:on_replace] == :copy))
            ensure_poll_handler_called
        end

        # Adds a new poll block on this instance
        #
        # @macro InstanceHandlerOptions
        # @yieldparam [Roby::Task] task the task on which the poll block is
        #   executed. It might be different than the one on which it has been
        #   added because of replacements.
        # @return [Object] an ID that can be used in {#remove_poll_handler}
        def poll(options = {}, &block)
            default_on_replace = abstract? ? :copy : :drop
            options = InstanceHandler.validate_options(
                options, on_replace: default_on_replace
            )

            check_arity(block, 1)
            handler = InstanceHandler.new(block, (options[:on_replace] == :copy))
            @poll_handlers << handler
            ensure_poll_handler_called
            Roby.disposable { @poll_handlers.delete(handler) }
        end

        # Remove a poll handler from this instance
        #
        # @param [Object] handler the ID returned by {#poll}
        # @return [void]
        def remove_poll_handler(handler)
            handler.dispose
        end

        # @api private
        #
        # Helper for {#execute} and {#poll} that ensures that the {#do_poll} is
        # called by the execution engine
        def ensure_poll_handler_called
            return if transaction_proxy? || !running?

            @poll_handler_id ||= execution_engine.add_propagation_handler(
                description: "poll block for #{self}",
                type: :external_events, &method(:do_poll)
            )
        end

        # @api private
        #
        # Method under which `Models::Task#poll` registers its given block.
        # Defined empty at this level to allow calling super() unconditionally
        def poll_handler; end

        # @api private
        #
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

                poll_handler

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
            #  - polling as defined in state of the state_machine, i.e.
            #    substates of running
            if respond_to?(:poll_handler) || !poll_handlers.empty? || state_machine
                @poll_handler_id = engine.add_propagation_handler(
                    description: "poll block of #{self}",
                    type: :external_events, &method(:do_poll)
                )
            end
        end

        on :stop do |ev|
            if @poll_handler_id
                execution_engine.remove_propagation_handler(@poll_handler_id)
            end
        end

        # Declares that this fault response table should be made active when
        # this task starts, and deactivated when it ends
        def use_fault_response_table(table_model, arguments = {})
            arguments = table_model.validate_arguments(arguments)

            table = nil
            execute do |task|
                table = task.plan.use_fault_response_table(table_model, arguments)
            end
            stop_event.on do |event|
                plan.remove_fault_response_table(table)
            end
        end

        # Whether this task instance provides a set of models and arguments
        #
        # The fullfills? predicate checks if this task can be used
        # to fullfill the need of the given model and arguments
        # The default is to check if
        #   * the needed task model is an ancestor of this task
        #   * the task
        #   * +args+ is included in the task arguments
        def fullfills?(models, args = nil)
            if models.kind_of?(Roby::Task)
                args ||= models.meaningful_arguments
                models = models.model
            end
            unless model.fullfills?(models)
                return false
            end

            args&.each do |key, name|
                if self.arguments[key] != name
                    return false
                end
            end

            true
        end

        # True if this model requires an argument named key and that argument is
        # set
        def has_argument?(key)
            self.arguments.set?(key)
        end

        # True if self can be used to replace target
        def can_replace?(target)
            fullfills?(*target.fullfilled_model)
        end

        # Tests if a task could be merged within self
        #
        # Unlike a replacement, a merge implies that self is modified to match
        # both its current role and the target's role. Roby has no built-in
        # merge logic (no merge method). This method is a helper for Roby
        # extensions that implement such a scheme, to check for attributes
        # common to all tasks that would forbid a merge
        def can_merge?(target)
            if defined?(super) && !super
                return false
            elsif finished? || target.finished?
                return false
            elsif !model.can_merge?(target.model)
                return false
            end

            arguments.can_semantic_merge?(target.arguments)
        end

        # "Simply" mark this task as terminated. This is meant to be used on
        # quarantined tasks in tests.
        #
        # Do not use this unless you really know what you are doing
        def forcefully_terminate
            update_task_status(event(:stop).new([]))
        end

        include ExceptionHandlingObject

        # @api private
        #
        # Handles the given exception.
        #
        # In addition to the exception handlers provided by
        # {ExceptionHandlingObject}, it checks for repair tasks (as defined by
        # TaskStructure::ErrorHandling)
        #
        # @param [ExecutionException] e
        def handle_exception(e)
            return unless plan

            tasks = find_all_matching_repair_tasks(e)
            return super if tasks.empty?

            tasks.first.start! if tasks.none?(&:running?)
            true
        end

        # Lists all exception handlers attached to this task
        def each_exception_handler(&iterator)
            model.each_exception_handler(&iterator)
        end

        # @api private
        #
        # Validates that both self and the child object are owned by the local
        # instance
        def add_child_object(child, type, info)
            unless read_write? && child.read_write?
                raise OwnershipError,
                      "cannot add a relation between tasks we don't own. #{self} by "\
                      "#{owners.to_a} and #{child} is owned by #{child.owners.to_a}"
            end

            super
        end

        # @api private
        #
        # This method is called during the commit process to apply changes
        # stored in a proxy
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

        # @api private
        #
        # Computes the list of edge replacements that might be necessary to
        # perform a replacement in a transaction-aware way
        #
        # At this stage, we make little difference between subplan and task
        # replacement
        #
        # @param [Boolean] with_subplan whether the subplan should be includede
        #   in edge discovery
        def compute_replacement_candidates(object, filter, with_subplan)
            edges, edges_candidates = [], []
            subplan_tasks = Set[self, object]
            subplan_tasks.compare_by_identity
            parent_tasks = Set.new
            parent_tasks.compare_by_identity
            plan.each_task_relation_graph do |g|
                next if g.strong? || filter.excluded_graph?(g)

                rel = g.class
                next if filter.excluded_relation?(rel)

                each_in_neighbour_merged(rel, intrusive: true) do |parent|
                    parent_tasks << parent
                    unless filter.excluded_task?(parent)
                        edges << [g, parent, self, parent, object]
                    end
                end

                if with_subplan || g.weak?
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

            transaction_stack = plan.each_object_in_transaction_stack(self).to_a
            object_transaction_stack = plan.each_object_in_transaction_stack(object).to_a
            event_pairs = []
            model.each_event do |_, event|
                event = transaction_stack
                    .find { |_, o| o.find_event(event.symbol) }
                    .last.event(event.symbol)
                object_event = object_transaction_stack
                    .find { |_, o| o.find_event(event.symbol) }
                    .last.event(event.symbol)
                event_pairs << [event, object_event]
            end

            plan.each_event_relation_graph do |g|
                next if g.strong? || filter.excluded_graph?(g)

                rel = g.class
                next if filter.excluded_relation?(rel)

                event_pairs.each do |event, object_event|
                    event.each_in_neighbour_merged(rel, intrusive: false) do |_, parent|
                        if parent.respond_to?(:task) &&
                           !transaction_stack.include?(parent.task)
                            edges_candidates << [
                                plan[parent.task],
                                [g, parent, event, parent, object_event]
                            ]
                        end
                    end
                    event.each_out_neighbour_merged(rel, intrusive: false) do |_, child|
                        if child.respond_to?(:task) &&
                           !transaction_stack.include?(child.task)
                            edges_candidates << [
                                plan[child.task],
                                [g, event, child, object_event, child]
                            ]
                        end
                    end
                end
            end

            [edges, edges_candidates, subplan_tasks, parent_tasks]
        end

        # @api private
        #
        # The compute_ methods work on a edge set that looks like this:
        #    [graph, [add_parent, add_child, remove_parent, remove_child]]
        # while Plan#apply_replacement_operations works on two sets
        #    [[graph, add_parent, add_child, info], ...]
        #    [[graph, remove_parent, remove_child], ...]
        # This transforms the first form into the second
        def transform_candidates_into_operations(edges)
            added, removed = [], []
            edges.each do |g, removed_parent, removed_child, added_parent, added_child|
                added_parent   = plan[added_parent]
                added_child    = plan[added_child]
                removed_parent = plan[removed_parent]
                removed_child  = plan[removed_child]
                info = g.edge_info(removed_parent, removed_child)

                added << [g, added_parent, added_child, info]
                unless g.copy_on_replace?
                    removed << [g, removed_parent, removed_child]
                end
            end
            [added, removed]
        end

        def compute_task_replacement_operation(object, filter)
            edges, edges_candidates, =
                compute_replacement_candidates(object, filter, true)
            edges_candidates.each do |reference_task, op|
                if filter.excluded_task?(reference_task)
                    next
                elsif reference_task == object || reference_task == self
                    next
                else
                    edges << op
                end
            end
            transform_candidates_into_operations(edges)
        end

        # @api private
        def compute_subplan_replacement_operation(object, filter)
            edges, edges_candidates, subplan_tasks, parent_tasks =
                compute_replacement_candidates(object, filter, false)
            edges_candidates.each do |reference_task, op|
                if filter.excluded_task?(reference_task)
                    next
                elsif subplan_tasks.include?(reference_task)
                    next
                elsif parent_tasks.include?(reference_task)
                    edges << op
                elsif plan.in_useful_subplan?(self, reference_task) ||
                      plan.in_useful_subplan?(object, reference_task)
                    subplan_tasks << reference_task
                else
                    edges << op
                end
            end
            transform_candidates_into_operations(edges)
        end

        # Replaces self by object
        #
        # It replaces self by object in all relations +self+ is part of, and do
        # the same for the task's event generators.
        #
        # @see replace_subplan_by
        def replace_by(object, filter: Plan::ReplacementFilter::Null.new)
            added, removed = compute_task_replacement_operation(object, filter)
            plan.apply_replacement_operations(added, removed)

            initialize_replacement(object)
            each_event do |event|
                event.initialize_replacement(nil) { object.event(event.symbol) }
            end
        end

        # Replaces self's subplan by another subplan
        #
        # Replaces the subplan generated by self by the one generated by object.
        # In practice, it means that we transfer all parent edges whose target
        # is self from the receiver to object. It calls the various add/remove
        # hooks defined in {DirectedRelationSupport}.
        #
        # Relations to free events are not copied during replacement
        #
        # @see replace_by
        def replace_subplan_by(object, filter: Plan::ReplacementFilter::Null.new)
            added, removed = compute_subplan_replacement_operation(object, filter)
            plan.apply_replacement_operations(added, removed)

            initialize_replacement(object)
            each_event do |event|
                event.initialize_replacement(object.event(event.symbol))
            end
        end

        # @api private
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

        # @deprecated this has no equivalent. It really has never seen proper support
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
            @service ||= plan.find_plan_service(self) || PlanService.new(self)
        end

        def as_plan
            self
        end

        # Register a hook that is called when this task is finalized (removed
        # from its plan)
        #
        # @macro InstanceHandlerOptions
        def when_finalized(options = {}, &block)
            default = abstract? ? :copy : :drop
            options, remaining =
                InstanceHandler.filter_options options, on_replace: default
            super(options.merge(remaining), &block)
        end

        def internal_error_handler(exception)
            return pass_exception unless exception.originates_from?(self)

            gen = exception.generator
            error = exception.exception
            if (gen == start_event) && !gen.emitted?
                failed_to_start!(error) unless failed_to_start?
            elsif !running?
                pass_exception
            elsif (!gen || !gen.terminal?) && !internal_error_event.emitted?
                internal_error_event.emit(error)
                if stop_event.pending? || !stop_event.controlable?
                    # In this case, we can't "just" stop the task. We have
                    # to inject +error+ in the exception handling and kill
                    # everything that depends on it.
                    execution_engine.add_error(
                        TaskEmergencyTermination.new(self, error, false)
                    )
                end
            else
                if execution_engine.display_exceptions?
                    # No nice way to isolate this error through the task
                    # interface, as we can't emergency stop it. Quarantine it
                    # and inject it in the normal exception propagation
                    # mechanisms.
                    execution_engine.fatal(
                        "#{self} failed to stop, putting in quarantine"
                    )
                    execution_engine.fatal "the error is:"
                    Roby.log_exception_with_backtrace(error, execution_engine, :fatal)
                end

                plan.quarantine_task(self, reason: exception.exception)
            end
        end
        private :internal_error_handler

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
        def +(other)
            # !!!! + is NOT commutative
            if other.null?
                self
            elsif self.null?
                other
            else
                Tasks::Sequence.new << self << other
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
        def |(other)
            if self.null?
                other
            elsif other.null?
                self
            else
                Tasks::Parallel.new << self << other
            end
        end

        def to_execution_exception
            ExecutionException.new(LocalizedError.new(self))
        end

        # @api private
        def create_transaction_proxy(transaction)
            transaction.create_and_register_proxy_task(self)
        end

        # Return a task match object that matches self
        #
        # @return [Queries::TaskMatcher]
        def match
            self.class.match.with_instance(self)
        end

        # Enumerate the coordination objects currently attached to this task
        #
        # @yieldparam [Coordination::Base] object
        def each_coordination_object(&block)
            @coordination_objects.each(&block)
        end

        # @api private
        #
        # Declare that a coordination object is attached to this task
        #
        # @param [Coordination::Base] object
        def add_coordination_object(object)
            @coordination_objects.push(object)
        end

        # @api private
        #
        # Declare that a coordination object is no longer attached to this task
        #
        # @param [Coordination::Base] object
        def remove_coordination_object(object)
            @coordination_objects.delete(object)
        end

        # Create an action state machine and attach it to this task
        #
        # Unlike `Actions::Interface#action_state_machine`, states must be
        # defined from explicit action objects
        def action_state_machine(&block)
            model = Coordination::ActionStateMachine
                .new_submodel(action_interface: nil, root: self.model)
            model.parse(&block)
            model.new(self)
        end
    end

    unless defined? TaskStructure
        TaskStructure = RelationSpace(Task)
        TaskStructure.default_graph_class = Relations::TaskRelationGraph
    end
end
