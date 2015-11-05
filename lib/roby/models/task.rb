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
            #   child = root.depends_on(TaskModel.with_arguments(:id => 200))
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
                super
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
                    inherited_attribute("#{name}_set", "#{name}_sets", :map => true) { Hash.new { |h, k| h[k] = ValueSet.new } }
                    def each_#{name}(model)
                        for obj in #{name}s(model)
                        yield(obj)
                        end
                        self
                    end
                    def #{name}s(model)
                        result = ValueSet.new
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
                                result[from] ||= ValueSet.new
                                result[from].merge(targets)
                            end
                            @all_#{name}s = result
                        end
                    end
                EOD
            end

            # The set of signals that are registered on this task model
            #
            # At the level of the task model, events are represented as subclasses
            # of TaskEvent. Therefore, the model-level mappings are stored between
            # these subclasses.
            #
            # @return [Hash<Model<TaskEvent>, ValueSet<Model<TaskEvent>>>]
            # @key_name source_generator
            model_attribute_list('signal')
            # The set of forwardings that are registered on this task model
            #
            # At the level of the task model, events are represented as subclasses
            # of TaskEvent. Therefore, the model-level mappings are stored between
            # these subclasses.
            #
            # @return [Hash<subclass of TaskEvent, ValueSet<subclass of TaskEvent>>]
            # @key_name source_generator
            model_attribute_list('forwarding')
            # The set of causal links that are registered on this task model
            #
            # At the level of the task model, events are represented as subclasses
            # of TaskEvent. Therefore, the model-level mappings are stored between
            # these subclasses.
            #
            # @return [Hash<subclass of TaskEvent, ValueSet<subclass of TaskEvent>>]
            # @key_name source_generator
            model_attribute_list('causal_link')
            # The set of event handlers that are registered on this task model
            #
            # At the level of the task model, events are represented as subclasses
            # of TaskEvent. Therefore, the model-level mappings are stored between
            # these subclasses.
            #
            # @return [Hash<subclass of TaskEvent, ValueSet<Proc>>]
            # @key_name generator
            model_attribute_list('handler')
            # The set of precondition handlers that are registered on this task model
            #
            # At the level of the task model, events are represented as subclasses
            # of TaskEvent. Therefore, the model-level mappings are stored between
            # these subclasses.
            #
            # @return [Hash<subclass of TaskEvent, ValueSet<Proc>>]
            # @key_name generator
            model_attribute_list('precondition')

            def from(object)
                if object.kind_of?(Symbol)
                    Roby.from(nil).send(object)
                else
                    Roby.from(object)
                end
            end

            def from_state(state_object = State)
                Roby.from_state(state_object)
            end

            # Declare that tasks of this model can finish by simply emitting
            # +stop+. Use it this way:
            #
            #   class MyTask < Roby::Task
            #     terminates
            #   end
            #
            # It adds a +stop!+ command that emits the +failed+ event.
	    def terminates
		event :failed, :command => true, :terminal => true
		interruptible
	    end

            # Declare that tasks of this model can be interrupted. It does so by
            # defining a command for +stop+, which in effect calls the command
            # for +failed+.
            #
            # Raises ArgumentError if failed is not controlable.
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

            ##
            # :singleton-method: abstract?
            #
            # True if this task is an abstract task.
            #
            # See Task::abstract() for more information.
            attr_predicate :abstract?, true

            # Declare that this task model defines abstract tasks. Abstract
            # tasks can be used to represent an action, without specifically
            # representing how this action should be done.
            #
            # Instances of abstract task models are not executable, i.e. they
            # cannot be started.
            #
            # See also #abstract? and #executable?
            def abstract
                @abstract = true
            end

            # Update the terminal flag for the event models that are defined in
            # this task model. The event is terminal if model-level signals (set up
            # by Task::on) lead to the emission of the +stop+ event
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
                            event sym, :model => ev, :terminal => true, 
                                :command => (ev.method(:call) rescue nil)
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
                    :controlable => nil, :command => nil, :terminal => nil,
                    :model => find_event_model(event_name) || Roby::TaskEvent

                if options.has_key?(:controlable)
                    options[:command] = options[:controlable]
                elsif !options.has_key?(:command) && block
                    options[:command] = define_command_method(event_name, block)
                end
                validate_event_definition_request(event_name, options)

                # Define the event class
                new_event = options[:model].new_submodel :task_model => self,
                    :terminal => options[:terminal],
                    :symbol => event_name, :command => options[:command]
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
            inherited_attribute(:event, :events, :map => true) { Hash.new }

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
        
            # call-seq:
            #   signal(name1 => name2, name3 => [name4, name5])
            #
            # Establish model-level signals between events of that task. These
            # signals will be established on all the instances of this task model
            # (and its subclasses).
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

                    signal_sets[from.symbol].merge targets.map { |ev| ev.symbol }.to_value_set
                end
                update_terminal_flag
            end

            # call-seq:
            #   on(event_name) { |event| ... }
            #
            # Adds an event handler for the given event model. The block is going to
            # be called whenever +event_name+ is emitted.
            def on(mappings, &user_handler)
                if user_handler
                    check_arity(user_handler, 1)
                end

                if mappings.kind_of?(Hash)
                    Roby.warn_deprecated "the on(event => event) form of Task.on is deprecated. Use #signal to establish signals"
                    signal(mappings)
                end

                mappings = [*mappings].zip([]) unless Hash === mappings
                mappings.each do |from, _|
                    from = event_model(from).symbol
                    if user_handler 
                        method_name = "event_handler_#{from}_#{Object.address_from_id(user_handler.object_id).to_s(16)}"
                        define_method(method_name, &user_handler)

                        handler = lambda { |event| event.task.send(method_name, event) }
                        handler_sets[from] << EventGenerator::EventHandler.new(handler, false, false)
                    end
                end
            end

            # call-seq:
            #   causal_link(:from => :to)
            #
            # Declares a causal link between two events in the task. See
            # EventStructure::CausalLink for a description of the causal link
            # relation.
            def causal_link(mappings)
                mappings.each do |from, to|
                    from = event_model(from).symbol
                    causal_link_sets[from].merge Array[*to].map { |ev| event_model(ev).symbol }.to_value_set
                end
                update_terminal_flag
            end

            # Defines a forwarding relation between two events of the same task
            # instance.
            #
            # @param [{Symbol=>Symbol}] mappings of event names, where the keys
            #   are forwarded to the values
            # @example
            #   # A task that is stopped as soon as it is started
            #   class MyTask < Roby::Task
            #     forward :start => :stop
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

                    forwarding_sets[from].merge targets.to_value_set
                end
                update_terminal_flag
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
                    raise "no block given"
                end

                define_method(:poll_handler, &block)
            end

            ##
            # :call-seq:
            #   on_exception(exception_class, ...) { |task, exception_object| ... }
            # 
            # Defines an exception handler. matcher === exception_object is used to
            # determine if the handler should be called when +exception_object+ has
            # been fired. The first matching handler is called. Call #pass_exception to pass
            # the exception to previous handlers
            #
            #   on_exception(TaskModelViolation, ...) do |task, exception_object|
            #	if cannot_handle
            #	    task.pass_exception # send to the next handler
            #	end
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

            def simulation_model
                if @simulation_model
                    return @simulation_model
                end

                base  = self
                model = Roby::Task.new_submodel
                arguments.each do |name|
                    model.argument name
                end
                each_event do |name, event_model|
                    if !model.has_event?(name) || (model.find_event_model(name).controlable? != event_model.controlable?)
                        model.event name, :controlable => event_model.controlable?, :terminal => event_model.terminal?
                    end
                end
                @simulation_model ||= model
            end

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
