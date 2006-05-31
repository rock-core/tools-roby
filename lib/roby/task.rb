require 'roby/event'
require 'roby/support'

module Roby
    class TaskModelViolation < ModelViolation
        attr_reader :task
        def initialize(task); @task = task end
        def to_s
	    if task
		history = task.history.map { |time, event| [time, event.name] }.join("\n  ")
		super + "\n#{task.name} (0x#{task.address.to_s(16)})\n  #{history.inspect}"
	    else
		super
	    end
        end
    end

    # Base class for task events
    # When events are emitted, then the created object is 
    # an instance of a class derived from this one
    class TaskEvent < Event
        # The task which fired this event
        attr_reader :task
        
        def initialize(task, generator, context = nil)
            @task = task
            super(generator, context)
        end

        # If the event model defines a controlable event
        # By default, an event is controlable if the model
        # responds to #call
        def self.controlable?; respond_to?(:call) end
        # If the event is controlable
        def controlable?; self.class.controlable? end
        # If the event model defines a terminal event
        def self.terminal?; @terminal end
        # If the event is terminal
        def terminal?; self.class.terminal? end
        # The event symbol
        def self.symbol; @symbol end
        # The event symbol
        def symbol; self.class.symbol end
    end

    # A task event model bound to a particular task instance
    # The Task/TaskEvent/TaskEventGenerator relationship is 
    # comparable to the Class/UnboundMethod/Method one:
    # * a Task object is a model for a task, a Class in a model for an object
    # * a TaskEvent object is a model for an event instance (the instance being unspecified), 
    #   an UnboundMethod is a model for an instance method
    # * a TaskEventGenerator object represents a particular event model 
    #   *bound* to a particular task instance, a Method object represents a particular method 
    #   bound to a particular object
    class TaskEventGenerator < EventGenerator
        attr_reader :task, :model
        def initialize(task, model)
	    if model.respond_to?(:call)
		super() do |context|
		    model.call(self.task, context)
		end
	    else
		super()
	    end

            @task, @model = task, model
        end

        def can_signal?(event); super || (event.respond_to?(:task) && task == event.task) end

        def fire(event)
            task.fire_event(event)
            super
        end

	def each_signal(&iterator)
	    super
	    task.each_signal(model.symbol) do |event_model|
		iterator[task.event(event_model)]
	    end
	end
	    
	def each_handler(&iterator)
	    super
	    task.each_handler(model.symbol, &iterator)
	end

        def controlable?; model.controlable? end
        def terminal?
	    model.terminal? || 
		enum_for(:each_signal).find { |ev| ev.respond_to?(:task) && ev.task == self.task && ev.terminal? } 
	end
	def active?(seen = Set.new)
	    if symbol == :start; super
	    elsif task.running?; true
	    else;		 task.event(:start).active?(seen)
	    end
	end
        def symbol;       model.symbol end
        def new(context); model.new(task, self, context) end

        def to_s
	    model_name = event_model.name
	    model_name.gsub! /^#{task.name}::/, ''
	    "#<#{self.name}:0x#{address.to_s(16)} task=#{task} model=#{model_name}>" end
    end

    class Task
	@@tasks = Hash.new { |h, k| h[k] = Array.new }
	def self.[](model)
	    @@tasks[model]
	end

	# Map which gives the model-level signals that come from a given
	# event model
	class_inherited_enumerable(:signal_set, :signal_sets, :map => true) { Hash.new { |h, k| h[k] = Set.new } }
	def self.each_signal(model, &iterator)
	    enum_for(:each_signal_set, model, false).
		inject(null_enum) { |a, b| a + b }.
		enum_uniq.each(&iterator)
	end
	def each_signal(model, &iterator); singleton_class.each_signal(model, &iterator) end

	# Map which gives the model-level event handlers attached to a
	# given event model
	class_inherited_enumerable(:handler_set, :handler_sets, :map => true) { Hash.new { |h, k| h[k] = Set.new } }
	def self.each_handler(model, &iterator)
	    enum_for(:each_handler_set, model, false).
		inject(null_enum) { |a, b| a + b }.
		enum_uniq.each(&iterator)
	end
	def each_handler(model, &iterator); singleton_class.each_handler(model, &iterator) end
	
        # Builds a task object using this task model
        # The task object can be configured by a given block. After the 
        # block is called, two things are checked:
        # * the task shall have a +start+ event
        # * the task shall have at least one terminal event. If no +stop+ event
        #   is defined, then all terminal events are aliased to +stop+
        def initialize #:yields: task_object
            @bound_events = Hash.new

            yield self if block_given?

            raise TaskModelViolation.new(self), "no start event defined" unless has_event?(:start)

            if !model.has_event?(:stop)
                # Create the stop event for this task, if it is not defined. Task::event will create
		# the signals between the terminal events and stop
                model.event(:stop)
            end

	    @@tasks[self.class] << self

            super if defined? super
        end

        def model; singleton_class end

        # If a model of +event+ is defined in the task model
        def has_event?(event); model.has_event?(event) end
        
        # If this task is currently running
        def running?; event(:start).happened? && !finished? end
        # If this task ran and is finished
        def finished?; model.terminal_events.find { |ev| event(ev).happened? } end

	def history
	    history = []
	    each_event do |event|
		history += event.history
	    end

	    history.sort_by { |time, _| time }
	end
            
        # This method is called by TaskEventGenerator#fire just before the event handlers
        # and commands are called
        def fire_event(event)
            if finished? && (!event.terminal? || event(:stop).happened?)
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}) called but the task has finished"
            elsif !running? && !finished? && event.symbol != :start
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}) called but the task is not running"
            elsif running? && event.symbol == :start
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}) called but the task is already running"
            end

	    super if defined? super
        end
        
        attr_reader :bound_events

        # call-seq:
        #   emit(event_model, context)                       event object
        #
        # Emits +event_model+ in the given +context+. Event handlers are fired.
        # This is equivalent to
        #   event(event_model).emit(context)
        #
        def emit(event_model, context = nil)
            event(event_model).emit(context)
            self
        end

	def name; model.name end

        # Returns an TaskEventGenerator object which is the given task event bound
        # to this particular task
        def event(event_model)
            event_model = *model.validate_event_models(event_model)
            bound_events[event_model] ||= TaskEventGenerator.new(self, event_model)
        end

        # call-seq:
        #   on(event_model[, task, event1, event2, ...]) { |event| ... }
        #
        # Adds an event handler for the given event model. When an event of this
        # model is fired by this task
        # * all provided events will be provoked in +task+. As such, all of these
        #   events shall be controlable
        # * the supplied handler will be called with the event object
        #
        def on(event_model, *args, &user_handler)
            unless args.size >= 2 || (args.size == 0 && user_handler)
                raise ArgumentError, "Bad call for Task#on. Got #{args.size + 1} arguments and #{block_given? ? 1 : 0} block"
            end

            generator = event(event_model)
            to_events = if args.size >= 2
                            to_task, *to_events = *args
                            to_events.map { |ev_model| to_task.event(ev_model) }
			    # generator#to_events will check that the generator in to_events
			    # can be signalled
                        else
                            []
                        end
            generator.on(*to_events, &user_handler)
            self
        end

        # :section: Event model
        
        # call-seq:
        #   self.event(name, options = nil)                   -> event class or nil
        #
        # Define a new event in this task. 
        #
        # ==== Available options
        #
        # <tt>:command</tt>::
        #   either an event command for the new event, which is an object which must respond
        #   to proc, +true+ or +false+. If it is true, a default handler is defined which 
        #   simply emits the event. +false+ can be used to override the automatic definition
        #   of the event command (see below).
        #
        # <tt>:terminal</tt>::
        #   set to true if this event is a terminal event
        #
        # <tt>:model</tt>::
        #   base class for the event model (see "Event models" below). The default is the 
        #   TaskEvent class
        #
        #
        # ==== Automatic event command
        #
        # If the task class defines a method with the same name as the
        # event, then the event is controlable, and this method is defined
        # as the event command.
        #
        # Setting the <tt>:command</tt> option explicitely to a false value overrides 
        # this behaviour (use +false+ or +nil+ to disable the command handler)
        #
        #
        # ==== Event models
        #
        # The event model is described using a Ruby class. Task::event defines a 
        # class, usually a subclass of TaskEvent and stores it in MyTask::MyEvent
        # for a my_event event. Then, when the event is emitted, the event object
        # will be an instance of this particular class. To override the base class
        # for a particular event, use the <tt>:model</tt> option
        #
        def self.event(ev, options = Hash.new)
            options = validate_options(options, :command => nil, :terminal => nil, :model => TaskEvent)

            ev_s = ev.to_s
            ev = ev.to_sym


            if !options.has_key?(:command) && instance_methods.include?(ev_s)
                method = instance_method(ev)
                check_arity(method, 1)
                options[:command] = lambda { |t, c| method.bind(t).call(c) }
            end
            validate_event_definition_request(ev, options)

            command_handler = options[:command] if options[:command].respond_to?(:call)
            
            # Define the event class
	    task_klass = self
            new_event = Class.new(options[:model]) do
                @symbol   = ev
                @terminal = options[:terminal]
                @command_handler = command_handler

		define_method(:name) { "#{task.name}::#{ev_s.camelize}" }
                singleton_class.class_eval do
                    attr_reader :command_handler
		    define_method(:name) { "#{task_klass.name}::#{ev_s.camelize}" }
		    def to_s; name end
                end
            end

	    events[new_event.symbol] = new_event
	    const_set(ev_s.camelize, new_event)

	    if options[:command]
		# check that the supplied command handler can take two arguments
		check_arity(command_handler, 2) if command_handler

		# define #call on the event model
                new_event.singleton_class.class_eval do
		    if command_handler
			define_method(:call, &command_handler)
		    else
			def call(task, context)
			    task.emit(symbol, context)
			end
		    end
                end

		# define an instance method which calls the event command
		define_method("#{ev_s}!") do |*context| 
		    context = *context
		    event(ev).call(context) 
		end
            end
		    
       	    if new_event.symbol == :stop
		terminal_events.each { |terminal| on(terminal) { |event| event.task.emit :stop } if terminal.symbol != :stop }
	    elsif options[:terminal] && has_event?(:stop)
		on(new_event) { |event| event.task.emit :stop }
	    end


	    new_event
        end

        def self.validate_event_definition_request(ev, options) #:nodoc:
            if ev.to_sym == :start && options[:terminal]
                raise TaskModelViolation.new(nil), "the 'start' event cannot be terminal"
            elsif options[:command] && options[:command] != true && !options[:command].respond_to?(:call)
                raise ArgumentError, "Allowed values for :command option: true, false, nil and an object responding to #call. Got #{options[:command]}"
            end

            if ev.to_sym == :stop
                if options.has_key?(:terminal) && !options[:terminal]
                    raise TaskModelViolation.new(nil), "the 'stop' event cannot be non-terminal"
                end
                options[:terminal] = true
            end

            # Check for inheritance rules
	    if events.include?(ev)
		raise ArgumentError, "event #{ev} already defined" 
            elsif old_event = find_event_model(ev)
                if old_event.terminal? && !options[:terminal]
                    raise ArgumentError, "trying to override a terminal event into a non-terminal one"
                elsif old_event.controlable? && !options[:command]
                    raise ArgumentError, "trying to override a controlable event into a non-controlable one"
                end
            end
        end

        # Events defined by the task model
        class_inherited_enumerable(:event, :events, :map => true) { Hash.new }

        # Iterates on all the events defined for this task
        def each_event(only_bound = true, &iterator) # :yield:bound_event
            if only_bound
                bound_events.each_value(&iterator)
            else
                model.each_event { |symbol, model| yield event(model) }
            end
        end

        # Get the list of terminal events for this task model
        def self.terminal_events
	    enum_for(:each_event).
		find_all { |_, e| e.terminal? }.
		map { |_, e| e }
	end

        # Get the event model for +event+. +event+ must follow the rules for validate_event_models
        def self.event_model(model)
            validate_event_models(model).first
        end
        def event_model(model); self.model.event_model(model) end

        # Find the event class for +event+, or nil if +event+ is not an event name for this model
        def self.find_event_model(name)
	    name = name.to_sym
	    each_event { |sym, e| return e if sym == name }
	    nil
        end

        # Checks that all events in +events+ are valid events for this task.
        # The requested events can be either an event name (symbol or string)
        # or an event class
        #
        # Returns the corresponding array of event classes
        def self.validate_event_models(*models) #:nodoc:
            models.map do |e|
                if e.respond_to?(:to_sym)
                    ev_model = find_event_model(e.to_sym)
                    unless ev_model
                        all_events = enum_for(:each_event).map { |name, _| name }
                        raise ArgumentError, "#{e} is not an event of #{name} #{all_events.inspect}" unless ev_model
                    end
                elsif e.respond_to?(:has_ancestor?) && e.has_ancestor?(TaskEvent)
                    # Check that e is an event class for us
                    ev_model = find_event_model(e.symbol)
                    if !ev_model
                        raise ArgumentError, "no #{e.symbol} event in #{name}"
                    elsif ev_model != e
                        raise ArgumentError, "the event model #{e} is not a model for #{name} (found #{ev_model} with the same name)"
                    end
                else 
                    raise ArgumentError, "wanted either a symbol or an event class, got #{e}"
                end

                ev_model
            end
        end
       
        class << self
            # Checks if _name_ is a name for an event of this task
            alias :has_event? :find_event_model

            private :validate_event_definition_request
        end
    
        # call-seq:
        #   on(event_model) { |event| ... }
        #   on(event_model => ev1, ev2 => [ ev3, ev4 ]) { |event| ... }
        #
        # Adds an event handler for the given event model. When the event is fired,
        # all events given in argument will be called. If they are controlable,
        # then the command is called. If not, they are just fired
        def self.on(mappings, &user_handler)
            mappings = [*mappings].zip([]) unless Hash === mappings
            mappings.each do |from, to|
                from = *validate_event_models(from).map { |ev| ev.symbol }
                to = if to; validate_event_models(*to).map { |ev| ev.symbol }
                     else;  []
                     end

		signal_sets[from] |= to.to_set
		handler_sets[from] << user_handler if user_handler
            end
        end

        def to_s; "#{model.name}(0x#{address.to_s(16)})" end
	    
        def null?; false end
	def to_task; self end
	
	event :success, :terminal => true
	event :failed,  :terminal => true

	def self.aborted(task, context)
	    events = task.enum_for(:each_child).
		find_all { |child| child.running? }.
		map { |child| child.event(:aborted) }

	    if events.empty?
		task.emit(:aborted)
	    else
		events.inject { |a, b| a & b }.on { task.emit(:aborted) }
		events.each { |ev| ev.call(context) }
	    end
	end
	event :aborted, :command => lambda { |task, context| Task.aborted(task, context) }
	on :aborted => :failed
    end

    class NullTask < Task
        event :start, :command => true
        event :stop
        on :start => :stop

        def null?; true end
    end
end

require 'roby/relations'
require 'roby/relations/hierarchy'
require 'roby/task-operations'

# Notes on event handlers, event commands and event models
#
#   * when an event if fired, it is done in a certain context, which
#     is the part of the state of the world which is relevant for this
#     event propagation.
#   * a fired event takes the form of an event object, which is an instance
#     of the event model (i.e. the event class defined by Task::event).
#     emit() creates this event object
#   * *all* event handlers are called with only one argument: this event object
#   * controlable events define a *singleton* method +call(task, context)+ whose
#     purpose is to lead to the emission of the given event on the given task
#     The context is event-specific

