require 'roby/relations'
require 'roby/event'
require 'roby/plan-object'
require 'weakref'

module Roby
    class TaskModelViolation < ModelViolation
        attr_reader :task
        def initialize(task); @task = task end
        def to_s
	    if task
		history = task.history.map do |time, event|
			"@%i[%s.%03i] %s" % [
			    event.propagation_id,
			    time.strftime("%Y/%m/%d %H:%M:%S"),
			    time.tv_usec / 1000,
			    event.name
			]
		    end

		super + "\n#{task.name} (0x#{task.address.to_s(16)}) history\n   #{history.join("\n   ")}"
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
        
        def initialize(task, generator, propagation_id, context = nil)
            @task = task
            super(generator, propagation_id, context)
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
        attr_reader :task, :event_model
        def initialize(task, model)
	    if model.respond_to?(:call)
		super() do |context|
		    model.call(self.task, context)
		end
	    else
		super()
	    end

            @task, @event_model = task, model
        end
	
	# The plan this event is part of
	def plan; task.plan end

	# True if a signal between self and +event+ can be established
        def can_signal?(event); super || (event.respond_to?(:task) && task == event.task) end
	# True if this event generator is executable (can be called and/or emitted)
	def executable?; task.executable? end

	# Fire the event
        def fire(event)
            task.fire_event(event)
            super
        end

	# Enumerates all signals that come from this generator
	def each_signal
	    super
	    task.each_signal(event_model.symbol) do |event_model|
		yield(task.event(event_model))
	    end
	end

	def each_handler
	    super
	    task.each_handler(event_model.symbol) { |o| yield(o) }
	end
	def each_precondition
	    super
	    task.each_precondition(event_model.symbol) { |o| yield(o) }
	end

        def controlable?; event_model.controlable? end
        def terminal?
	    return true if event_model.terminal?
	    each_signal { |ev| return true if ev.respond_to?(:task) && ev.task == self.task && ev.terminal? } 
	    false
	end
	def active?(seen = Set.new)
	    if symbol == :start; super
	    elsif task.running?; true
	    else;		 task.event(:start).active?(seen)
	    end
	end
        def symbol;       event_model.symbol end
        def new(context); event_model.new(task, self, EventGenerator.propagation_id, context) end

	def to_s
	    "#{task}/#{symbol}"
	end
    end

    # Tasks represent processes in a plan. Task subclasses model specific tasks
    # Tasks are made of events, which are
    # defined by calling Task::event on a Task class.
    #
    # === Executability
    # By default, a task is not executable, which means that no event command
    # can be called and no event can be emitted. A task becomes executable either
    # because Task#executable= has been called or because it has been inserted
    # in a Plan object. This constraint has been added to make sure that no
    # task is executed outside of the plan supervision. Note that tasks inserted
    # in transactions are *not* executable either. An abstract task is a task
    # which can never be executed. Call Task::abstract in the class definition
    # to make a task abstract.
    #
    # === Inheritance
    # * a task subclass has all events of its parent class
    # * some event attributes can be overriden. The rules are:
    #   - a non-controlable event can become a controlable one
    #   - a non-terminal event can become a terminal one
    class Task < PlanObject
	include DirectedRelationSupport

	def name; model(false).name end

	@@tasks = Hash.new

	# Enumerates all tasks of model +model+ defined in the system. 
	def self.each_task(model)
	    return unless tasks = @@tasks[model]
	    tasks.each do |t|
		if t.weakref_alive?
		    t = t.__getobj__ rescue nil
		    yield(t) if t
		end
	    end
	end

	def self.model_attribute_list(name)
	    class_inherited_enumerable("#{name}_set", "#{name}_sets", :map => true) { Hash.new { |h, k| h[k] = Set.new } }
	    class_eval <<-EOD
		class << self
		    attribute("__#{name}_enumerator__") { Hash.new }
		end

		def self.each_#{name}_aux(model)
		    each_#{name}_set(model, false) { |models| models.each { |m| yield(m) } }
		end
		def self.each_#{name}(model)
		    enumerator = (__#{name}_enumerator__[model] ||= enum_for(:each_#{name}_aux, model))
		    enumerator.each_uniq { |o| yield(o) }
		end
		def each_#{name}(model); singleton_class.each_#{name}(model) { |o| yield(o) } end
	    EOD
	end

	model_attribute_list('signal')
	model_attribute_list('handler')
	model_attribute_list('precondition')

	# The task arguments as a hash
	attr_reader :arguments
	
        # Builds a task object using this task model
	#
        # The task object can be configured by a given block. After the 
        # block is called, two things are checked:
        # * the task shall have a +start+ event
        # * the task shall have at least one terminal event. If no +stop+ event
        #   is defined, then all terminal events are aliased to +stop+
        def initialize(arguments = nil) #:yields: task_object
	    @arguments = (arguments || {}).to_hash
            @bound_events = Hash.new

            yield self if block_given?

            raise TaskModelViolation.new(self), "no start event defined" unless has_event?(:start)

            if !model.has_event?(:stop)
                # Create the stop event for this task, if it is not defined. Task::event will create
		# the signals between the terminal events and stop
                model.event(:stop)
            end

	    @@tasks[self.class] ||= []
	    @@tasks[self.class] << WeakRef.new(self)

	    super() if defined? super
        end

	def plan=(new_plan)
	    if !pending? && @plan != new_plan
		raise TaskModelViolation.new(self), "cannot change the plan of a running task"
	    end
	    super
	end

	class << self
	    # If this task is an abstract task
	    # Abstract tasks are not executable. This attribute is
	    # not inherited in the task hierarchy
	    attr_reader :abstract
	    alias :abstract? :abstract

	    # Mark this task model as an abstract model
	    def abstract
		@abstract = true
	    end
	end

	# Roby::Task is an abstract model
	abstract

	# Check if this task is executable
	def executable?; !self.class.abstract? && super end
	# Set the executable flag. executable cannot be set to +false+ is the 
	# task is running, and cannot be set to true on a finished task.
	def executable=(flag)
	    return if flag == @executable
	    if flag && !pending? 
		raise TaskModelViolation.new(self), "cannot set the executable flag on a task which is not pending"
	    elsif !flag && running?
		raise TaskModelViolation.new(self), "cannot unset the executable flag on a task which is running"
	    end
	    super
	end

	# Returns the task model
        def model(create = true)
	    if create || has_singleton?; singleton_class 
	    else self.class
	    end
	end

        # If a model of +event+ is defined in the task model
        def has_event?(event); model.has_event?(event) end
        
	# If this task never ran
	def pending?; !event(:start).happened? end
        # If this task is currently running
        def running?; event(:start).happened? && !finished? end
	# A terminal event that has already happened. nil if the task
	# is not finished
	def final_event
	    each_event { |ev| return ev if ev.terminal? && ev.happened? } 
	    nil
	end
        # If this task ran and is finished
	def finished?; !!final_event end
	# If this task ran and succeeded
	def success?; event(:success).happened? end
	
	# Remove all relations in which +self+ or its event are involved
	def clear_relations
	    each_event { |ev| ev.clear_vertex }
	    self.clear_vertex
	end

	# List of [time, event] pair for all events that
	# have already been achieved in this task.
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
	    if !executable?
		raise NotExecutable.new(self), "trying to fire #{event.generator.symbol} on #{self} but #{self} is not executable"
	    end

	    final_event = self.final_event
	    final_event = final_event.last if final_event

            if final_event && final_event.propagation_id != event.propagation_id
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} but the task has finished"
            elsif !running? && !finished? && event.symbol != :start
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} but the task is not running"
            elsif running? && event.symbol == :start
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} but the task is already running"
            end

	    super if defined? super
        end
        
	# List of EventGenerator objects bound to this task
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

        # Returns an TaskEventGenerator object which is the given task event bound
        # to this particular task
        def event(event_model)
            event_model = self.event_model(event_model)
            event = (bound_events[event_model] ||= TaskEventGenerator.new(self, event_model))
	    event.executable = self.executable?
	    event
        end

        # call-seq:
        #   on(event_model[, task, event1, event2, ...]) { |event| ... }
        #
        # Adds an event handler for the given event model. When an event of this
        # model is fired by this task
        # * all provided events will be called in +task+. As such, all of these
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

	attr_accessor :calling_event
	def method_missing(name, *args, &block)
	    if calling_event && calling_event.respond_to?(name)
		calling_event.send(name, *args, &block)
	    else
		super
	    end
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
        def self.event(ev, options = Hash.new, &block)
            options = validate_options(options, :command => block, :terminal => nil, :model => TaskEvent)

            ev_s = ev.to_s
            ev = ev.to_sym


            if !options.has_key?(:command) && method_defined?(ev_s)
                method = instance_method(ev)
                check_arity(method, 1)
                options[:command] = lambda do |t, c| 
		    begin
			t.calling_event = t.event(ev)
			method.bind(t).call(c) 
		    ensure
			t.calling_event = nil
		    end
		end
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
		    if !executable?
			raise NotExecutable.new(self), "cannot call event command #{ev_s} on #{self} because the task is not executable"
		    end

		    context = *context # emulate default value for blocks
		    event(ev).call(context) 
		end
            end
		    
       	    if new_event.symbol == :stop
		terminal_events.each { |terminal| on(terminal) { |event| event.task.emit(:stop, event.context) } if terminal.symbol != :stop }
	    elsif options[:terminal] && has_event?(:stop)
		on(new_event) { |event| event.task.emit(:stop, event.context) }
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
                model(false).each_event { |symbol, model| yield event(model) }
            end
        end

        # Get the list of terminal events for this task model
        def self.terminal_events
	    enum_for(:each_event).
		find_all { |_, e| e.terminal? }.
		map { |_, e| e }
	end

        # Get the event model for +event+
        def event_model(model); self.model(false).event_model(model) end

        # Find the event class for +event+, or nil if +event+ is not an event name for this model
        def self.find_event_model(name)
	    name = name.to_sym
	    each_event { |sym, e| return e if sym == name }
	    nil
        end

	def check_relation_same_plan(child, type, info)
	    if child.plan && plan && child.plan != plan
		raise InvalidPlanOperation, "trying to establish a relation of type #{type} between two tasks not of the same plan"
	    end
	end
	def adding_child_object(child, type, info)
	    super if defined? super
	    check_relation_same_plan(child, type, info)
	end
	def adding_parent_object(child, type, info)
	    super if defined? super
	    check_relation_same_plan(child, type, info)
	end

        # Checks that all events in +events+ are valid events for this task.
        # The requested events can be either an event name (symbol or string)
        # or an event class
        #
        # Returns the corresponding array of event classes
        def self.event_model(model_def) #:nodoc:
	    if model_def.respond_to?(:to_sym)
		ev_model = find_event_model(model_def.to_sym)
		unless ev_model
		    all_events = enum_for(:each_event).map { |name, _| name }
		    raise ArgumentError, "#{model_def} is not an event of #{name}: #{all_events}" unless ev_model
		end
	    elsif model_def.respond_to?(:has_ancestor?) && model_def.has_ancestor?(TaskEvent)
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
                from = event_model(from).symbol
                to = if to; Array[*to].map { |ev| event_model(ev).symbol }
                     else;  []
                     end

		signal_sets[from] |= to.to_set
		handler_sets[from] << user_handler if user_handler
            end
        end

	def self.precondition(event, reason, &block)
	    event = event_model(event)
	    precondition_sets[event.symbol] << [reason, block]
	end

        def to_s; name end
	def pretty_print(pp)
	    pp.text to_s
	    pp.group(2, ' {', '}') do
		pp.breakable
		pp.text "relations: "
		pp.seplist(relations) { |r| pp.text r.name }

		pp.breakable
		pp.text "arguments: "
		pp.pp arguments

		pp.breakable
		pp.text "bound events: "
		pp.seplist(bound_events) { |e| pp.text e[1].symbol.to_s }
	    end
	end
	    
        def null?; false end
	def to_task; self end
	
	event :start, :command => true
	event :success, :terminal => true
	event :failed,  :terminal => true

	event :aborted, :terminal => true
	on(:aborted) { |event| event.task.emit(:failed, event.context) }

	# Checks if +task+ is in the same execution state than +self+
	# Returns true if they are either both running or both pending
	def same_state?(task)
	    !(finished? || task.finished?) && !(running? ^ task.running?)
	end

	# The fullfills? predicate checks if this task can be used
	# to fullfill the need of the given +model+ and +arguments+
	# The default is to check if
	#   * the needed task model is an ancestor of this task
	#   * +args+ is included in the task arguments
	def fullfills?(model, args = {})
	    if Task === model
		model, args = model.class, model.arguments
	    end
	    (self.model == model || self.kind_of?(model)) && self.arguments.slice(*args.keys) == args
	end

	class_inherited_enumerable('exception_handler', 'exception_handlers') { Array.new }

	# call-seq:
	#   task_model.on_exception(TaskModelViolation, ...) { |task, exception_object| ... }
	#   task_model.on_exception(TaskModelViolation, ...) do |task, exception_object|
	#	....
	#	task.pass
	#   end
	#
	# Defines an exception handler. We use matcher === exception_object
	# to determine if the handler should be called when +exception_object+
	# has been fired. The first matching handler is called. Call #pass
	# to pass the exception to previous handlers
	def self.on_exception(*matchers, &handler)
	    exception_handlers.unshift [matchers, handler]
	end

	# Passes the exception to the next matching exception handler
	def pass_exception
	    throw :next_exception_handler
	end

	# Calls the exception handlers defined in this task for +exception_object.exception+
	# Returns true if the exception has been handled, false otherwise
	def handle_exception(exception_object)
	    model(false).each_exception_handler do |matchers, handler|
		if matchers.find { |m| m === exception_object.exception }
		    catch(:next_exception_handler) do 
			handler[self, exception_object]
			return true
		    end
		end
	    end
	    return false
	end
    end

    TaskStructure   = RelationSpace(Task)

    class NullTask < Task
        event :start, :command => true
        event :stop
        on :start => :stop

        def null?; true end
    end
end

require 'roby/relations/hierarchy'
require 'roby/task-operations'

