require 'roby/plan-object'
require 'roby/exceptions'
require 'roby/event'

module Roby
    class TaskModelTag < Module
	module ClassExtension
	    # Returns the list of static arguments required by this task model
	    def arguments; enum_for(:each_argument_set).to_set end
	    # Declares a set of arguments required by this task model
	    def argument(*args); args.each(&argument_set.method(:<<)) end
	end
	include TaskModelTag::ClassExtension

	def initialize(&block)
	    super do
		inherited_enumerable("argument_set", "argument_set") { Set.new }
		unless const_defined? :ClassExtension
		    const_set(:ClassExtension, Module.new)
		end

		self::ClassExtension.include TaskModelTag::ClassExtension
	    end
	    class_eval(&block) if block_given?
	end
    end

    class TaskModelViolation < ModelViolation
        attr_reader :task
        def initialize(obj)
	    @task = if obj.respond_to?(:to_task) then obj
		    elsif obj.respond_to?(:task) then obj.task
		    else raise TypeError, "not a task" 
		    end
	end
        def to_s
	    if task
		history = task.history.map do |event|
			"@%i[%s.%03i] %s" % [
			    event.propagation_id,
			    event.time.strftime("%Y/%m/%d %H:%M:%S"),
			    event.time.tv_usec / 1000,
			    event.name
			]
		    end

		super + "\n#{task.name} (0x#{task.address.to_s(16)}) history\n   #{history.join("\n   ")}"
	    else
		super
	    end
        end
    end

    class TaskNotExecutable < TaskModelViolation; end

    # Base class for task events
    # When events are emitted, then the created object is 
    # an instance of a class derived from this one
    class TaskEvent < Event
        # The task which fired this event
        attr_reader :task
        
        def initialize(task, generator, propagation_id, context, time = Time.now)
            @task = task
            super(generator, propagation_id, context, time)
        end

        # If the event model defines a controlable event
        # By default, an event is controlable if the model
        # responds to #call
        def self.controlable?; respond_to?(:call) end
        # If the event is controlable
        def controlable?; self.class.controlable? end
	class << self
	    # Called by Task.update_terminal_flag to update the flag
	    attr_writer :terminal
	end
        # If the event model defines a terminal event
        def self.terminal?; @terminal end
	# If this event is terminal
	def terminal?; generator.terminal? end
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

	alias :root_object :task 

	def read_only?; super && task.read_only? end
	def owners; task.owners end
	def local?; task.local? end
	def distribute?; task.distribute? end
	def has_sibling?(peer); task.has_sibling?(peer) end
	def subscribed?; task.subscribed? end
	
	# The plan this event is part of
	def plan; task.plan end
	def plan=(plan); task.plan=plan end

	# True if a signal between self and +event+ can be established
        def can_signal?(event); super || (event.respond_to?(:task) && task == event.task) end
	# True if this event generator is executable (can be called and/or emitted)
	def executable?; task.executable? end

	# Fire the event
        def fire(event)
            task.fire_event(event)
            super
        end

	def related_tasks(result = nil)
	    tasks = super
	    tasks.delete(task)
	    tasks
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
	attr_writer :terminal
	def terminal?; @terminal || event_model.terminal? end
	def added_child_object(child, relation, info)
	    super if defined? super
	    if relation == EventStructure::CausalLink && child.respond_to?(:task) && child.task == task
		task.update_terminal_flag
	    end
	end
	def removed_child_object(child, relation)
	    super if defined? super
	    if relation == EventStructure::CausalLink && child.respond_to?(:task) && child.task == task
		task.update_terminal_flag
	    end
	end
        def symbol;       event_model.symbol end
        def new(context); event_model.new(task, self, Propagation.propagation_id, context) end

	def to_s
	    "#{task}/#{symbol}"
	end
	def inspect
	    "#{task.inspect}/#{symbol}: #{history.to_s}"
	end
    end

    class TaskArguments < Hash
	private :delete, :delete_if

	attr_reader :task
	def initialize(task)
	    @task = task
	    super()
	end

	def writable?(key)
	    !(has_key?(key) && task.model.arguments.include?(key))
	end

	def dup; self.to_hash end
	def to_hash
	    inject({}) { |h, (k, v)| h[k] = v ; h }
	end

	def []=(key, value)
	    if writable?(key)
		updating
		super
		updated
	    else
		raise ArgumentError, "cannot override task arguments"
	    end
	end
	def updating; super if defined? super end
	def updated; super if defined? super end

	def merge!(hash)
	    super do |key, old, new|
		if old == new then old
		elsif writable?(key) then new
		else
		    raise ArgumentError, "cannot override task arguments"
		end
	    end
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
	include TaskModelTag.new

	def self.model_attribute_list(name)
	    inherited_enumerable("#{name}_set", "#{name}_sets", :map => true) { Hash.new { |h, k| h[k] = Set.new } }
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
		def each_#{name}(model); self.model.each_#{name}(model) { |o| yield(o) } end
	    EOD
	end

	model_attribute_list('signal')
	model_attribute_list('handler')
	model_attribute_list('precondition')

	# The task arguments as symbol => value associative container
	attr_reader :arguments
	# The part of +arguments+ that is meaningful for this task model
	def meaningful_arguments(task_model = self.model)
	    arguments.slice(*task_model.arguments)
	end
	# The task name
	attr_reader :name

	def inspect
	    state = if pending? then 'pending'
		    elsif starting? then 'starting'
		    elsif running? then 'running'
		    elsif finishing? then 'finishing'
		    else 'finished'
		    end
	    "#<#{to_s} executable=#{executable?} state=#{state} plan=#{plan.to_s}>"
	end
	
        # Builds a task object using this task model
	#
        # The task object can be configured by a given block. After the 
        # block is called, two things are checked:
        # * the task shall have a +start+ event
        # * the task shall have at least one terminal event. If no +stop+ event
        #   is defined, then all terminal events are aliased to +stop+
        def initialize(arguments = nil) #:yields: task_object
	    @arguments = TaskArguments.new(self).merge(arguments || {})
            @bound_events = Hash.new
	    @name = "#{model.name || self.class.name}#{arguments.to_s}:0x#{address.to_s(16)}"

            yield self if block_given?

            raise TaskModelViolation.new(self), "no start event defined" unless has_event?(:start)
	    super() if defined? super
        end

	def plan=(new_plan)
	    if plan != new_plan
		if plan && plan.include?(self)
		    raise TaskModelViolation.new(self), "still included in #{plan}, cannot change the plan"
		elsif self_owned? && running?
		    raise TaskModelViolation.new(self), "cannot change the plan of a running task"
		end
	    end
	    super

	rescue TypeError
	    raise TypeError, "#{self} is dead because it has been removed from its plan"
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

	    def terminates
		event :failed, :command => true, :terminal => true
		interruptible
	    end
	    def interruptible
		if !has_event?(:failed) || !event_model(:failed).controlable?
		    raise ArgumentError, "failed is not controlable"
		end
		define_method(:stop) do |context|
		    failed!(context)
		end
		event :stop
	    end
	    def polls
		if !instance_method?(:poll)
		    raise ArgumentError, "#{self} does not define a 'poll' instance method"
		end
		poll(&method(:poll))
	    end
	    def poll(&block)
		if !block_given?
		    raise "no block given"
		end

		define_method(:poll, &block)
		on(:start) { |event| Control.event_processing << event.task.method(:poll) }
		on(:stop) { |event| Control.event_processing.delete(event.task.method(:poll)) }
	    end
	end

	# Roby::Task is an abstract model
	abstract

	def abstract?; self.class.abstract? end
	# Check if this task is executable
	def executable?; !self.class.abstract? && !partially_instanciated? && super end
	# Set the executable flag. executable cannot be set to +false+ is the 
	# task is running, and cannot be set to true on a finished task.
	def executable=(flag)
	    return if flag == @executable
	    return unless self_owned?
	    if flag && !pending? 
		raise TaskModelViolation.new(self), "cannot set the executable flag on a task which is not pending"
	    elsif !flag && running?
		raise TaskModelViolation.new(self), "cannot unset the executable flag on a task which is running"
	    end
	    super
	end
	
	# Check that all arguments required by the task model are set
	def fully_instanciated?; @fully_instanciated ||= (model.arguments - arguments.keys.to_set).empty? end
	# Returns true if one argument required by the task model is not set
	def partially_instanciated?; !fully_instanciated? end

	# Returns the task model
        def model
	    if has_singleton?; singleton_class 
	    else self.class
	    end
	end

        # If a model of +event+ is defined in the task model
        def has_event?(event); model.has_event?(event) end
        
	def starting?; event(:start).pending? end
	# If this task never ran
	def pending?; !started? end
        # If this task is currently running
        def running?; started? && !finished? end
	# A terminal event that has already happened. nil if the task
	# is not finished
	attr_reader :final_event
	def finishing?
	    if running?
		each_event { |ev| return true if ev.terminal? && ev.pending? }
	    end
	    false
	end
        # If this task ran and is finished
	attr_reader :__started
	alias :started? :__started
	attr_reader :__finished
	alias :finished? :__finished
	attr_reader :__success
	alias :success? :__success
	def failed?; finished? && !success? end

	# Remove all relations in which +self+ or its event are involved
	def clear_relations
	    each_event { |ev| ev.clear_relations }
	    super
	end

	# Update the terminal flag for the event models that are defined in this
	# task model. The event is terminal if model-level signals (set up by Task::on)
	# lead to the emission of the +stop+ event
	def self.update_terminal_flag # :nodoc:
	    events = enum_for(:each_event).map { |name, model| model }
	    terminal_events = events.find_all { |ev| ev.terminal? }

	    found = true
	    while found
		found = false
		events -= terminal_events

		events.each do |ev|
		    each_signal(ev.symbol) do |signalled|
			if event_model(signalled).terminal?
			    found = true
			    ev.terminal = true
			    terminal_events << ev
			    break
			end
		    end
		end
	    end
	end

	# Updates the terminal flag for all events in the task. An event is
	# terminal if the +stop+ event of the task will be called because this
	# event is.
	def update_terminal_flag
	    events = bound_events.values
	    terminal_events = events.find_all do |ev|
		# remove the terminal flag, TaskEventGenerator#terminal?  will
		# now return the model's terminal flag
		ev.terminal = false
		ev.terminal?
	    end

	    found = true
	    while found
		found = false
		events -= terminal_events

		events.each do |ev|
		    ev.each_causal_link do |signalled|
			if signalled.terminal?
			    found = true
			    ev.terminal = true
			    terminal_events << ev
			    break
			end
		    end
		end
	    end
	end

	# List of [time, event] pair for all events that
	# have already been achieved in this task.
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
	    each_event(false) do |ev|
		ev.related_tasks(result)
	    end

	    result
	end
	def related_events(result = nil)
	    each_event(false) do |ev|
		result = ev.related_events(result)
	    end

	    result.reject { |ev| ev.respond_to?(:task) && ev.task == self }.
		to_value_set
	end
            
        # This method is called by TaskEventGenerator#fire just before the event handlers
        # and commands are called
        def fire_event(event)
	    if !executable?
		raise EventNotExecutable.new(self), "trying to fire #{event.generator.symbol} on #{self} but #{self} is not executable"
	    end

            if final_event && !event.terminal?
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} but the task has finished"
            elsif pending? && event.symbol != :start
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} but the task is not running"
            elsif running? && event.symbol == :start
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} but the task is already running"
            end

	    update_task_status(event)

	    super if defined? super
        end

	# Call to update the task status because of +event+
	def update_task_status(event)
	    if event.symbol == :success
		@__success = true
	    elsif event.symbol == :start
		@__started = true
	    end

	    if event.terminal?
		@final_event = event
		@__finished = true
	    end
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
	    unless event = bound_events[event_model]
		event_model = self.event_model(event_model)
		event_symbol = event_model.symbol
		unless event = bound_events[event_symbol]
		    event = 
			bound_events[event_symbol] = 
			TaskEventGenerator.new(self, event_model)

		    if event_symbol != :start && event_symbol != :stop
			event(:start).add_precedence(event)
		    end
		    model.each_signal(event_symbol) do |signalled|
			event.add_signal event(signalled)
		    end
		end

		event.executable = self.executable?
	    end
	    event
        end

        # call-seq:
        #   on(event, task[, event1, event2, ...])
	#   on(event) { |event| ... }
        #   on(event[, task, event1, event2, ...]) { |event| ... }
        #
        # Adds an event handler for the given event model. When the corresponding
	# event is fired,
	# * all signalled events will be called in +task+. As such, all of
	#   these events shall be controlable
        # * the supplied handler will be called with the event object
	#
	#   on(event, task)
	# is equivalent to 
	#   on(event, task, event)
        #
        def on(event_model, to_task = nil, *to_events, &user_handler)
            unless to_task || user_handler
                raise ArgumentError, "you must provide either a task or an event handler"
            end

            generator = event(event_model)
	    if to_task
		if to_events.empty?
		    to_events << generator.symbol
		end
		to_events.map! { |ev_model| to_task.event(ev_model) }
	    end
            generator.on(*to_events, &user_handler)
            self
        end

	# Fowards +event_model+ to the events in +to_events+ on task +to_task+
	# If no destination events are given, use the event in +to_task+ with
	# the same name than +event_model+: the two following lines are equivalent:
	#   t1.forward(:start, t2, :start)
	#   t1.forward(:start, t2)
	#
	def forward(event_model, to_task, *to_events)
            generator = event(event_model)
	    if to_events.empty?
		to_events << generator.symbol
	    end

            to_events.each do |ev_model| 
		ev = to_task.event(ev_model)
		ev.emit_on generator
	    end
	end

	attr_accessor :calling_event
	def method_missing(name, *args, &block)
	    if calling_event && calling_event.respond_to?(name)
		calling_event.send(name, *args, &block)
	    else
		super
	    end
	rescue
	    raise $!, $!.message, $!.backtrace[1..-1]
	end

        # :section: Event model
        
        # call-seq:
        #   self.event(name, options = nil) { ... } -> event class or nil
        #
        # Define a new event in this task. 
        #
        # ==== Available options
        #
        # <tt>:command</tt>::
        #   either an event command for the new event, which is an object which must respond
        #   to proc, +true+ or +false+. If it is true, a default handler is defined which 
        #   simply emits the event. +false+ can be used to override the automatic definition
        #   of the event command (see below). If a block is given, it is used as the event
	#   command.
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
	@@event_command_id = 0
	def self.allocate_event_command_id
	    @@event_command_id += 1
	end
        def self.event(ev, options = Hash.new, &block)
            options = validate_options(options, :command => nil, :terminal => nil, :model => TaskEvent)
	    if block
	    end

            ev_s = ev.to_s
            ev = ev.to_sym

            if !options.has_key?(:command)
		if block
		    id = allocate_event_command_id
		    define_method("event_command_#{id}", &block)
		    method = instance_method("event_command_#{id}")
		elsif method_defined?(ev_s)
		    method = instance_method(ev)
		end

		if method
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

	    # Check that the event is now terminal while it was not before
	    setup_terminal_handler = false
	    old_model = find_event_model(ev)
	    if new_event.symbol != :stop && options[:terminal] && (!old_model || !old_model.terminal?)
		setup_terminal_handler = true
	    end

	    events[new_event.symbol] = new_event
	    if setup_terminal_handler
		on(new_event) { |event| event.task.emit(:stop, event.context) }
	    end
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
			raise TaskNotExecutable.new(self), "cannot call event command #{ev_s} on #{self} because the task is not executable"
		    end

		    context = *context # emulate default value for blocks
		    event(ev).call(context) 
		end
            end


	    new_event
        end

        def self.validate_event_definition_request(ev, options) #:nodoc:
            if ev.to_sym == :start && options[:terminal]
                raise ArgumentError, "the 'start' event cannot be terminal"
            elsif options[:command] && options[:command] != true && !options[:command].respond_to?(:call)
                raise ArgumentError, "Allowed values for :command option: true, false, nil and an object responding to #call. Got #{options[:command]}"
            end

            if ev.to_sym == :stop
                if options.has_key?(:terminal) && !options[:terminal]
                    raise ArgumentError, "the 'stop' event cannot be non-terminal"
                end
                options[:terminal] = true
            end

            # Check for inheritance rules
	    if events.include?(ev)
		raise ArgumentError, "event #{ev} already defined" 
            elsif old_event = find_event_model(ev)
                if old_event.terminal? && !options[:terminal]
                    raise ArgumentError, "trying to override a terminal event into a non-terminal one", caller(2)
                elsif old_event.controlable? && !options[:command]
                    raise ArgumentError, "trying to override a controlable event into a non-controlable one", caller(2)
                end
            end
        end

        # Events defined by the task model
        inherited_enumerable(:event, :events, :map => true) { Hash.new }

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

        # Get the event model for +event+
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
		update_terminal_flag
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
		if bound_events
		    pp.seplist(bound_events) { |e| pp.text e[1].symbol.to_s }
		end
	    end
	end
	    
        def null?; false end
	def to_task; self end
	
	event :start, :command => true

	# Define :stop before any other terminal event
	event :stop
	event :success, :terminal => true
	event :failed,  :terminal => true

	event :aborted, :terminal => true
	on(:aborted) { |event| event.task.emit(:failed, event.context) }

	attr_reader :data
	def data=(value)
	    @data = value
	    updated_data
	    emit :updated_data if running?
	end
	def updated_data
	    super if defined? super
	end
	event :updated_data, :command => false

	# Checks if +task+ is in the same execution state than +self+
	# Returns true if they are either both running or both pending
	def compatible_state?(task)
	    finished? || !(running? ^ task.running?)
	end

	def self.tags
	    ancestors.find_all { |m| m.instance_of?(TaskModelTag) }
	end

	# The fullfills? predicate checks if this task can be used
	# to fullfill the need of the given +model+ and +arguments+
	# The default is to check if
	#   * the needed task model is an ancestor of this task
	#   * the task 
	#   * +args+ is included in the task arguments
	def fullfills?(models, args = {})
	    if models.kind_of?(Task)
		klass, tags, args = 
		    models.class, 
		    models.class.tags,
		    models.meaningful_arguments
		models = tags.push(klass)
	    else
		models = [*models]
	    end
	    self_model = self.model

	    # Check the arguments that are required by the model
	    required_args = models.inject(Set.new) do |required_args, tag|
		unless self_model.has_ancestor?(tag)
		    return false
		end
		required_args.merge tag.arguments
	    end
	    required_args = required_args.to_a

	    unknown_args = (args.keys - required_args)
	    unless unknown_args.empty?
		raise ArgumentError, "the arguments '#{unknown_args.join(", ")}' are unknown to the tags #{tags.join(", ")}"
	    end

	    arguments.slice(*args.keys) == args
	end

	include ExceptionHandlingObject
	inherited_enumerable('exception_handler', 'exception_handlers') { Array.new }
	def each_exception_handler(&iterator); model.each_exception_handler(&iterator) end

	@@exception_handler_id = 0

	# call-seq:
	#   task_model.on_exception(TaskModelViolation, ...) { |task, exception_object| ... }
	#   task_model.on_exception(TaskModelViolation, ...) do |task, exception_object|
	#	....
	#	task.pass_exception # send to the next handler
	#   end
	#
	# Defines an exception handler. We use matcher === exception_object
	# to determine if the handler should be called when +exception_object+
	# has been fired. The first matching handler is called. Call #pass
	# to pass the exception to previous handlers
	def self.on_exception(*matchers, &handler)
	    id = (@@exception_handler_id += 1)
	    define_method("exception_handler_#{id}", &handler)
	    exception_handlers.unshift [matchers, instance_method("exception_handler_#{id}")]
	end
    end

    class NullTask < Task
        event :start, :command => true
        event :stop
        on :start => :stop

        def null?; true end
    end

    TaskStructure   = RelationSpace(Task)
end

require 'roby/task-operations'

