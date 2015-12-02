module Roby
    module Models
        module Task
            include MetaRuby::ModelAsClass
            include Models::Arguments

            # Proxy class used as intermediate by Task.with_arguments
            class AsPlanProxy
                def initialize(model, arguments)
                    @model, @arguments = model, arguments
                end

                def as_plan
                    @model.as_plan(@arguments)
                end
            end

            class Template < TemplatePlan
                attr_reader :events_by_name
                attr_accessor :success_events
                attr_accessor :failure_events
                attr_accessor :terminal_events

                def initialize
                    super
                    @events_by_name = Hash.new
                end
            end

            # The plan that is used to instantiate this task model
            def template
                return @template if @template

                template = Template.new
                each_event do |event_name, event_model|
                    template.add(event = EventGenerator.new(controlable: event_model.controlable?))
                    template.events_by_name[event_name] = event
                end

                instantiate_event_relations(template)
                @template = template
            end

            def instantiate_event_relations(template)
                events = template.events_by_name

                all_signals.each do |generator, signalled_events|
                    next if signalled_events.empty?
                    generator = events[generator]

                    for signalled in signalled_events
                        signalled = events[signalled]
                        generator.signals signalled
                    end
                end

                all_forwardings.each do |generator, signalled_events|
                    next if signalled_events.empty?
                    generator = events[generator]

                    for signalled in signalled_events
                        signalled = events[signalled]
                        generator.forward_to signalled
                    end
                end

                all_causal_links.each do |generator, signalled_events|
                    next if signalled_events.empty?
                    generator = events[generator]

                    for signalled in signalled_events
                        signalled = events[signalled]
                        generator.add_causal_link signalled
                    end
                end

                # Add a link from internal_event to stop if stop is controllable
                if events[:stop].controlable?
                    events[:internal_error].signals events[:stop]
                end

                terminal_events, success_events, failure_events =
                    compute_terminal_events(events)

                template.terminal_events = terminal_events
                template.success_events   = success_events
                template.failure_events  = failure_events
                start_event = events[:start]

                # WARN: the start event CAN be terminal: it can be a signal from
                # :start to a terminal event
                #
                # Create the precedence relations between 'normal' events and the terminal events
                root_terminal_events = terminal_events.find_all do |ev|
                    (ev != start_event) && ev.root?(Roby::EventStructure::Precedence)
                end

                events.each_value do |ev|
                    next if ev == start_event
                    if !terminal_events.include?(ev)
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

            def discover_terminal_events(events, terminal_set, set, root)
                stack = [root]
                while !stack.empty?
                    vertex = stack.shift
                    for relation in [EventStructure::Signal, EventStructure::Forwarding]
                        for parent in vertex.parent_objects(relation)
                            if !events.include?(parent)
                                next
                            elsif parent[vertex, relation]
                                next
                            elsif !terminal_set.include?(parent)
                                terminal_set  << parent
                                set   << parent if set
                                stack << parent
                            end
                        end
                    end
                end
            end

            def compute_terminal_events(events)
                success_events, failure_events, terminal_events =
                    [events[:success]].to_set, 
                    [events[:failed]].to_set,
                    [events[:stop], events[:success], events[:failed]].to_set

                event_set = events.values.to_set
                discover_terminal_events(event_set, terminal_events, success_events, events[:success])
                discover_terminal_events(event_set, terminal_events, failure_events, events[:failed])
                discover_terminal_events(event_set, terminal_events, nil, events[:stop])
                return terminal_events, success_events, failure_events
            end

            # If this class model has an 'as_plan', this specifies what arguments
            # should be passed to as_plan
            def with_arguments(arguments = Hash.new)
                if respond_to?(:as_plan)
                    AsPlanProxy.new(self, arguments)
                else
                    raise NoMethodError, "#with_arguments is invalid on #self, as #self does not have an #as_plan method"
                end
            end

            # Default implementation of the #as_plan method
            #
            # The #as_plan method is used to use task models as representation of
            # abstract actions. For instance, if an #as_plan method is available on
            # a particular MoveTo task model, one can do
            #
            #   root.depends_on(MoveTo)
            #
            # This default implementation looks for planning methods declared in the
            # main Roby application planners that return the required task type or
            # one of its subclasses. If one is found, it is using it to generate the
            # action. Otherwise, it falls back to returning a new instance of this
            # task model, unless the model is abstract in which case it raises
            # ArgumentError.
            #
            # It can be used with
            #
            #   class TaskModel < Roby::Task
            #   end
            #
            #   root = Roby::Task.new
            #   child = root.depends_on(TaskModel)
            #
            # If arguments need to be given, the #with_arguments method should be
            # used:
            #
            #   root = Roby::Task.new
            #   child = root.depends_on(TaskModel.with_arguments(id: 200))
            #
            def as_plan(arguments = Hash.new)
                Roby.app.prepare_action(self, **arguments).first
            rescue Application::ActionResolutionError
                if abstract?
                    raise Application::ActionResolutionError, "#{self} is abstract and no planning method exists that returns it"
                else
                    Robot.warn "no planning method for #{self}, and #{self} is not abstract. Returning new instance"
                    new(arguments)
                end
            end

            # @deprecated
            #
            # Use #each_submodel instead
            def all_models
                submodels
            end

            # Clears all definitions saved in this model. This is to be used by the
            # reloading code
            def clear_model
                class_eval do
                    # Remove event models
                    events.each_key do |ev_symbol|
                        remove_const ev_symbol.to_s.camelcase(:upper)
                    end

                    [@events, @signal_sets, @forwarding_sets, @causal_link_sets,
                        @argument_set, @handler_sets, @precondition_sets].each do |set|
                        set.clear if set
                    end
                end
                super
            end

            # Declares an attribute set which follows the task models inheritance
            # hierarchy. Define the corresponding enumeration methods as well.
            #
            # For instance,
            #   model_attribute_list 'signal'
            #
            # defines the model-level signals, which can be accessed through
            #   .each_signal(model)
            #   .signals(model)
            #   #each_signal(model)
            #   
            def self.model_attribute_list(name) # :nodoc:
                class_eval <<-EOD, __FILE__, __LINE__+1
                    inherited_attribute("#{name}_set", "#{name}_sets", map: true) { Hash.new { |h, k| h[k] = Set.new } }
                    def each_#{name}(model)
                        for obj in #{name}s(model)
                            yield(obj)
                        end
                        self
                    end
                    def #{name}s(model)
                        result = Set.new
                        each_#{name}_set(model, false) do |set|
                            result.merge set
                        end
                        result
                    end

                    def all_#{name}s
                        if @all_#{name}s
                            @all_#{name}s
                        else
                            result = Hash.new
                            each_#{name}_set do |from, targets|
                                result[from] ||= Set.new
                                result[from].merge(targets)
                            end
                            @all_#{name}s = result
                        end
                    end
                EOD
            end

            def self.model_relation(name)
                model_attribute_list(name)
            end
                

            # @!group Event Relations

            # The set of signals that are registered on this task model
            model_relation 'signal'

            # The set of forwardings that are registered on this task model
            model_relation('forwarding')

            # The set of causal links that are registered on this task model
            model_relation('causal_link')

            # The set of event handlers that are registered on this task model
            model_attribute_list('handler')

            # The set of precondition handlers that are registered on this task model
            model_attribute_list('precondition')

            # Establish model-level signals between events of that task. These
            # signals will be established on all the instances of this task model
            # (and its subclasses).
            #
            # Signals cause the target event(s) command to be called when the
            # source event is emitted.
            # 
            # @param [Hash<Symbol,Array<Symbol>>,Hash<Symbol,Symbol>] mappings the source-to-target mappings
            # @raise [ArgumentError] if the target event is not controlable,
            #   i.e. not have a command
            #
            # @example when establishing multiple relations from the same source use name-to-arrays
            #   signal start: [:one, :two]
            def signal(mappings)
                mappings.each do |from, to|
                    from    = event_model(from)
                    targets = Array[*to].map { |ev| event_model(ev) }

                    if from.terminal?
                        non_terminal = targets.find_all { |ev| !ev.terminal? }
                        if !non_terminal.empty?
                            raise ArgumentError, "trying to establish a signal from the terminal event #{from} to the non-terminal events #{non_terminal}"
                        end
                    end
                    non_controlable = targets.find_all { |ev| !ev.controlable? }
                    if !non_controlable.empty?
                        raise ArgumentError, "trying to signal #{non_controlable.join(" ")} which is/are not controlable"
                    end

                    signal_sets[from.symbol].merge targets.map { |ev| ev.symbol }
                end
                update_terminal_flag
            end

            # Establish model-level causal links between events of that task. These
            # signals will be established on all the instances of this task
            # model (and its subclasses).
            #
            # Causal links are used during event propagation to order the
            # propagation properly. Establish a causal link when e.g. an event
            # handler might call or emit on another of this task's event
            # 
            # @param [Hash<Symbol,Array<Symbol>>,Hash<Symbol,Symbol>] mappings the source-to-target mappings
            #
            # @example when establishing multiple relations from the same source use name-to-arrays
            #   signal start: [:one, :two]
            def causal_link(mappings)
                mappings.each do |from, to|
                    from = event_model(from).symbol
                    causal_link_sets[from].merge Array[*to].map { |ev| event_model(ev).symbol }
                end
                update_terminal_flag
            end

            # Establish model-level forwarding between events of that task.
            # These relations will be established on all the instances of this
            # task model (and its subclasses).
            #
            # Forwarding is used to cause the target event to be emitted when
            # the source event is.
            #
            # @param [Hash<Symbol,Array<Symbol>>,Hash<Symbol,Symbol>] mappings the source-to-target mappings
            # @example
            #   # A task that is stopped as soon as it is started
            #   class MyTask < Roby::Task
            #     forward start: :stop
            #   end
            #
            # @see Task#forward
            # @see EventGenerator#forward.
            # @see Roby::EventStructure::Forward the forwarding relation.
            def forward(mappings)
                mappings.each do |from, to|
                    from    = event_model(from).symbol
                    targets = Array[*to].map { |ev| event_model(ev).symbol }

                    if event_model(from).terminal?
                        non_terminal = targets.find_all { |name| !event_model(name).terminal? }
                        if !non_terminal.empty?
                            raise ArgumentError, "trying to establish a forwarding relation from the terminal event #{from} to the non-terminal event(s) #{targets}"
                        end
                    end

                    forwarding_sets[from].merge targets
                end
                update_terminal_flag
            end

            # @!endgroup

            # Helper method to define delayed arguments from related objects
            #
            # @example propagate an argument from a parent task
            #    argument :target, default: from(:parent).target
            def from(object)
                if object.kind_of?(Symbol)
                    Roby.from(nil).send(object)
                else
                    Roby.from(object)
                end
            end

            # Helper method to define delayed arguments from the State object
            #
            # @example get an argument from the State object
            #    argument :initial_pose, default: from_state.pose
            def from_state(state_object = State)
                Roby.from_state(state_object)
            end

            # Declare that tasks of this model can finish by simply emitting
            # stop, i.e. with no specific action.
            #
            # @example
            #   class MyTask < Roby::Task
            #     terminates
            #   end
            #
	    def terminates
		event :failed, command: true, terminal: true
		interruptible
	    end

            # Declare that tasks of this model can be interrupted by calling the
            # command of {Roby::Task#failed_event}
            #
            # @raise [ArgumentError] if {Roby::Task#failed_event} is not controlable.
	    def interruptible
		if !has_event?(:failed) || !event_model(:failed).controlable?
		    raise ArgumentError, "failed is not controlable"
		end

		event(:stop) do |context| 
		    if starting?
			signals :start, self, :stop
			return
		    end
		    failed!(context)
		end
	    end

            # True if this task is an abstract task
            #
            # @see abstract
            attr_predicate :abstract?, true

            # Declare that this task model defines abstract tasks. Abstract
            # tasks can be used to represent an action, without specifically
            # representing how this action should be done.
            #
            # Instances of abstract task models are not executable, i.e. they
            # cannot be started.
            #
            # @see abstract? executable?
            def abstract
                @abstract = true
            end

            # @api private
            #
            # Update the terminal flag for the event models that are defined in
            # this task model. The event is terminal if model-level signals
            # ({#signal}) or forwards ({#forward}) lead to the
            # emission of {#stop_event}
            def update_terminal_flag # :nodoc:
                events = enum_events.map { |name, _| name }
                terminal_events = [:stop]
                events.delete(:stop)

                loop do
                    old_size = terminal_events.size
                    events.delete_if do |ev|
                        if signals(ev).any? { |sig_ev| terminal_events.include?(sig_ev) } ||
                            forwardings(ev).any? { |sig_ev| terminal_events.include?(sig_ev) }
                            terminal_events << ev
                            true
                        end
                    end
                    break if old_size == terminal_events.size
                end

                terminal_events.each do |sym|
                    if ev = self.events[sym]
                        ev.terminal = true
                    else
                        ev = superclass.event_model(sym)
                        unless ev.terminal?
                            event sym, model: ev, terminal: true, 
                                command: (ev.method(:call) rescue nil)
                        end
                    end
                end
            end

            # Defines a new event on this task. 
            #
            # @param [Symbol] event_name the event name
            # @param [Hash] options an option hash
            # @option options [Boolean] :controllable if true, the event is
            #   controllable and will use the default command of emitting directly
            #   in the command
            # @option options [Boolean] :terminal if true, the event is marked as
            #   terminal, i.e. it will terminate the task upon emission. Giving this
            #   flag is required to redeclare an existing terminal event in a
            #   subclass. Otherwise, it is determined automatically by checking
            #   whether the event is forwarded to :stop
            # @option options [Class] :model the base class used to create the
            #   model for this event. This class is going to be used to generate the
            #   event. Defaults to TaskEvent.
            #
            # When a task event (for instance +start+) is emitted, a Roby::TaskEvent
            # object is created to describe the information related to this
            # emission (time, sources, context information, ...). Task.event
            # defines a specific event model MyTask::MyEvent for each task event
            # with name :my_event. This specific model is by default a subclass of
            # Roby::TaskEvent, but it is possible to override that by using the +model+
            # option.
            def event(event_name, options = Hash.new, &block)
                event_name = event_name.to_sym

                options = validate_options options,
                    controlable: nil, command: nil, terminal: nil,
                    model: find_event_model(event_name) || Roby::TaskEvent

                if options.has_key?(:controlable)
                    options[:command] = options[:controlable]
                elsif !options.has_key?(:command) && block
                    options[:command] = define_command_method(event_name, block)
                end
                validate_event_definition_request(event_name, options)

                # Define the event class
                new_event = options[:model].new_submodel task_model: self,
                    terminal: options[:terminal],
                    symbol: event_name, command: options[:command]
                new_event.permanent_model = self.permanent_model?

                setup_terminal_handler = false
                old_model = find_event_model(event_name)
                if new_event.symbol != :stop && options[:terminal] && (!old_model || !old_model.terminal?)
                    setup_terminal_handler = true
                end

                events[new_event.symbol] = new_event
                if setup_terminal_handler
                    forward(new_event => :stop)
                end
                const_set(event_name.to_s.camelcase(:upper), new_event)

                define_event_methods(event_name)
                new_event
            end

            # @api private
            #
            # Define the method that will be used as command for the given event
            #
            # @param [Symbol] event_name the event name
            def define_command_method(event_name, block)
                check_arity(block, 1)
                define_method("event_command_#{event_name}", &block)
                method = instance_method("event_command_#{event_name}")
                lambda do |dst_task, *event_context| 
                    begin
                        dst_task.calling_event = dst_task.event(event_name)
                        method.bind(dst_task).call(*event_context) 
                    ensure
                        dst_task.calling_event = nil
                    end
                end
            end

            # @api private
            #
            # Define support methods for a task event
            #
            # @param [Symbol] event_name the event name
            def define_event_methods(event_name)
                if !method_defined?("#{event_name}_event")
                    define_method("#{event_name}_event") do
                        event(event_name)
                    end
                end
                if !method_defined?("#{event_name}?")
                    define_method("#{event_name}?") do
                        event(event_name).happened?
                    end
                end
                if !method_defined?("#{event_name}!")
                    define_method("#{event_name}!") do |*context| 
                        generator = event(event_name)
                        generator.call(*context) 
                    end
                end
                if !respond_to?("#{event_name}_event")
                    singleton_class.class_eval do
                        define_method("#{event_name}_event") do
                            find_event_model(event_name)
                        end
                    end
                end
            end

            # @api private
            #
            # Validate the parameters passed to {#event}
            #
            # @raise [ArgumentError] if there are inconsistencies / errors in
            #   the arguments
            def validate_event_definition_request(event_name, options) #:nodoc:
                if options[:command] && options[:command] != true && !options[:command].respond_to?(:call)
                    raise ArgumentError, "Allowed values for :command option: true, false, nil and an object responding to #call. Got #{options[:command]}"
                end

                if event_name.to_sym == :stop
                    if options.has_key?(:terminal) && !options[:terminal]
                        raise ArgumentError, "the 'stop' event cannot be non-terminal"
                    end
                    options[:terminal] = true
                end

                # Check for inheritance rules
                if events.include?(event_name)
                    raise ArgumentError, "event #{event_name} already defined" 
                elsif old_event = find_event_model(event_name)
                    if old_event.terminal? && !options[:terminal]
                        raise ArgumentError, "trying to override #{old_event.symbol} in #{self} which is terminal into a non-terminal event"
                    elsif old_event.controlable? && !options[:command]
                        raise ArgumentError, "trying to override #{old_event.symbol} in #{self} which is controlable into a non-controlable event"
                    end
                end
            end

            # The events defined by the task model
            #
            # @return [Hash<Symbol,TaskEvent>]
            inherited_attribute(:event, :events, map: true) { Hash.new }

            def enum_events # :nodoc
                @__enum_events__ ||= enum_for(:each_event)
            end

            # Get the list of terminal events for this task model
            def terminal_events
                enum_events.find_all { |_, e| e.terminal? }.
                    map { |_, e| e }
            end

            # Find the event class for +event+, or nil if +event+ is not an event name for this model
            def find_event_model(name)
                find_event(name.to_sym)
            end

            # Accesses an event model
            #
            # This method gives access to this task's event models. If given a
            # name, it returns the corresponding event model. If given an event
            # model, it verifies that the model is part of the events of self
            # and returns it.
            #
            # @return [Model<TaskEvent>] a subclass of Roby::TaskEvent
            # @raise [ArgumentError] if the provided event name or model does not
            #   exist on self
            def event_model(model_def) #:nodoc:
                if model_def.respond_to?(:to_sym)
                    ev_model = find_event_model(model_def.to_sym)
                    unless ev_model
                        all_events = enum_events.map { |name, _| name }
                        raise ArgumentError, "#{model_def} is not an event of #{name}: #{all_events}" unless ev_model
                    end
                elsif model_def.respond_to?(:has_ancestor?) && model_def.has_ancestor?(Roby::TaskEvent)
                    # Check that model_def is an event class for us
                    ev_model = find_event_model(model_def.symbol)
                    if !ev_model
                        raise ArgumentError, "no #{model_def.symbol} event in #{name}"
                    elsif ev_model != model_def
                        raise ArgumentError, "the event model #{model_def} is not a model for #{name} (found #{ev_model} with the same name)"
                    end
                else 
                    raise ArgumentError, "wanted either a symbol or an event class, got #{model_def}"
                end

                ev_model
            end
           
            # Checks if _name_ is a name for an event of this task
            alias :has_event? :find_event_model

            private :validate_event_definition_request
        
            # Adds an event handler for the given event model. The block is
            # going to be called whenever some events are emitted.
            #
            # Unlike a block given to {EventGenerator#on}, the block is
            # evaluated in the context of the task instance.
            #
            # @param [Array<Symbol>] event_names the name of the events on which
            #   to install the handler
            # @yieldparam [Object] context the arguments passed to {Roby::Task#emit}
            #   when the event was emitted
            def on(*event_names, &user_handler)
                if !user_handler
                    raise ArgumentError, "#on called without a block"
                end

                check_arity(user_handler, 1)
                event_names.each do |from|
                    from = event_model(from).symbol
                    if user_handler 
                        method_name = "event_handler_#{from}_#{Object.address_from_id(user_handler.object_id).to_s(16)}"
                        define_method(method_name, &user_handler)

                        handler = lambda { |event| event.task.send(method_name, event) }
                        handler_sets[from] << EventGenerator::EventHandler.new(handler, false, false)
                    end
                end
            end


            def precondition(event, reason, &block)
                event = event_model(event)
                precondition_sets[event.symbol] << [reason, block]
            end

            # Returns the lists of tags this model fullfills.
            def provided_services
                ancestors.find_all { |m| m.kind_of?(Models::TaskServiceModel) }
            end

            # Declares that the given block should be called at each execution
            # cycle, when the task is running. Use it that way:
            #
            #   class MyTask < Roby::Task
            #     poll do
            #       ... do something ...
            #     end
            #   end
            #
            # If the given polling block raises an exception, the task will be
            # terminated by emitting its +failed+ event.
            def poll(&block)
                if !block_given?
                    raise ArgumentError, "no block given"
                end

                define_method(:poll_handler, &block)
            end

            # Defines an exception handler.
            #
            # When propagating exceptions, {ExecutionException} goes up in the
            # task hierarchy and calls matching handlers on the tasks it finds,
            # and on their planning task. The first matching handler is called,
            # and the exception propagation assumes that it handled the
            # exception (i.e. won't look for new handlers) unless it calls
            # {Roby::Task#pass_exception}
            #
            # @param [#to_execution_exception_matcher] matcher object for
            #   exceptions. Subclasses of {LocalizedError} have it (matching the
            #   exception class) as well as {Task} (matches exception origin).
            #   See {Roby::Queries} for more advanced exception matchers.
            #
            # @yieldparam [ExecutionException] exception the exception that is
            #   being handled
            #
            # @example install a handler for a TaskModelViolation exception
            #   on_exception(TaskModelViolation, ...) do |task, exception_object|
            #	    if cannot_handle
            #	        task.pass_exception # send to the next handler
            #	    end
            #       do_handle
            #   end
            def on_exception(matcher, &handler)
                check_arity(handler, 1)
                matcher = matcher.to_execution_exception_matcher
                id = (@@exception_handler_id += 1)
                define_method("exception_handler_#{id}", &handler)
                exception_handlers.unshift [matcher, instance_method("exception_handler_#{id}")]
            end

            @@exception_handler_id = 0

            # Returns a TaskMatcher object that matches this task model
            def match(*args)
                matcher = Queries::TaskMatcher.new
                if args.empty? && self != Task
                    matcher.which_fullfills(self)
                else
                    matcher.which_fullfills(*args)
                end
                matcher
            end

            # @return [Queries::ExecutionExceptionMatcher] an exception match
            #   object that matches exceptions originating from this task
            def to_execution_exception_matcher
                Queries::ExecutionExceptionMatcher.new.with_origin(self)
            end

            def fullfills?(models)
                if models.respond_to?(:each)
                    models = models.to_a
                else models = [models]
                end
                models = models.inject([]) do |models, m|
                    if m.respond_to?(:each_fullfilled_model)
                        models.concat(m.each_fullfilled_model.to_a)
                    else
                        models << m
                    end
                end

                # Check the arguments that are required by the model
                for tag in models
                    if !has_ancestor?(tag)
                        return false
                    end
                end
                return true
            end

            def can_merge?(target_model)
                fullfills?(target_model)
            end

            def to_coordination_task(task_model)
                Roby::Coordination::Models::TaskFromAsPlan.new(self, self)
            end
        end
    end
end
