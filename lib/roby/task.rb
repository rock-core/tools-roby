require 'roby/plan-object'
require 'roby/exceptions'
require 'roby/event'
require 'utilrb/module/attr_predicate'

module Roby
    class TaskModelTag < Module
	module ClassExtension
	    # Returns the list of static arguments required by this task model
	    def arguments(*new_arguments)
		new_arguments.each do |arg_name|
		    argument_set << arg_name.to_sym
		    unless method_defined?(arg_name)
			define_method(arg_name) { arguments[arg_name] }
		    end
		end

	       	@argument_enumerator ||= enum_for(:each_argument_set)
	    end
	    # Declares a set of arguments required by this task model
	    def argument(*args); arguments(*args) end
	end
	include TaskModelTag::ClassExtension

	def initialize(&block)
	    super do
		inherited_enumerable("argument_set", "argument_set") { ValueSet.new }
		unless const_defined? :ClassExtension
		    const_set(:ClassExtension, Module.new)
		end

		self::ClassExtension.include TaskModelTag::ClassExtension
	    end
	    class_eval(&block) if block_given?
	end

	def clear_model
	    @argument_set.clear if @argument_set
	end
    end

    class TaskModelViolation < ModelViolation
	# The task from which this exception has been raised
        attr_reader :task
	# The task history when the exception has been created
	attr_reader :history
        def initialize(obj)
	    @task = if obj.respond_to?(:to_task) then obj
		    elsif obj.respond_to?(:task) then obj.task
		    else raise TypeError, "not a task" 
		    end
	    @history = task.history
	end
        def to_s
	    task_name = task.name
	    history = self.history.map do |event|
		    "@%i[%s.%03i] %s" % [
			event.propagation_id,
			event.time.strftime("%Y/%m/%d %H:%M:%S"),
			event.time.tv_usec / 1000,
			event.name.gsub(task_name, "")
		    ]
		end

	    super + "\n#{task_name} (0x#{task.address.to_s(16)}) history\n   #{history.join("\n   ")}"
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
	    @terminal_flag = generator.terminal_flag
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
	def success?; @terminal_flag == :success end
	# If this event is terminal
	def failure?; @terminal_flag == :failure end
	# If this event is terminal
	def terminal?; @terminal_flag end
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
	# The task we are part of
        attr_reader :task
	# The event symbol (its name as a Symbol object)
	attr_reader :symbol
	# The event class
	attr_reader :event_model
        def initialize(task, model)
            @task, @event_model = task, model
	    @symbol = model.symbol
	    super(model.respond_to?(:call))
        end

	def default_command(context)
	    event_model.call(task, context)
	end

	# See PlanObject::child_plan_object. 
	child_plan_object :task

	# The event plan. It is the same as task.plan and is actually updated
	# by task.plan=. It is redefined here for performance reasons.
	attr_accessor :plan

	# Fire the event
        def fire(event)
            task.fire_event(event)
            super
        end

	# See EventGenerator#fired
	#
	# In TaskEventGenerator, this hook calls the unreachable handlers added
	# by EventGenerator#if_unreachable when the task has finished, not
	# before
	def fired(event)
	    super if defined? super
	    
	    if symbol == :stop
		task.each_event { |ev| ev.unreachable! }
	    end
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
	attr_accessor :terminal_flag
	def terminal?; !!@terminal_flag end
	def success?; @terminal_flag == :success end
	def failure?; @terminal_flag == :failure end
	def added_child_object(child, relation, info)
	    super if defined? super

	    if relation == EventStructure::CausalLink && 
		child.respond_to?(:task) && child.task == task &&
		    child.terminal_flag != terminal_flag

		task.update_terminal_flag
	    end
	end
	def removed_child_object(child, relation)
	    super if defined? super

	    if relation == EventStructure::CausalLink
		child.respond_to?(:task) && child.task == task &&
		    terminal_flag

		task.update_terminal_flag
	    end
	end
        def new(context); event_model.new(task, self, Propagation.propagation_id, context) end

	def to_s
	    "#{task}/#{symbol}"
	end
	def inspect
	    "#{task.inspect}/#{symbol}: #{history.to_s}"
	end

	def achieve_with(obj)
	    child_task, child_event = case obj
				      when Roby::Task: [obj, obj.event(:success)]
				      when Roby::TaskEventGenerator: [obj.task, obj]
				      end

	    if child_task
		unless task.realized_by?(child_task)
		    task.realized_by child_task, 
			:success => [child_event.symbol],
			:remove_when_done => true
		end
		super(child_event)
	    else
		super(obj)
	    end
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
		if !task.read_write?
		    raise NotOwner, "cannot change the argument set of a task which is not owned #{task} is owned by #{task.owners} and #{task.plan} by #{task.plan.owners}"
		end

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
		    raise ArgumentError, "cannot override task argument #{key}: trying to replace #{old} by #{new}"
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
	unless defined? RootTaskTag
	    RootTaskTag = TaskModelTag.new
	    include RootTaskTag
	end

	def self.clear_model
	    class_eval do
		# Remove event models
		events.each_key do |ev_symbol|
		    remove_const ev_symbol.to_s.camelize
		end

		[@events, @signal_sets, @forwarding_sets, @causal_link_sets,
		    @argument_set, @handler_sets, @precondition_sets].each do |set|
		    set.clear if set
		end
	    end
	end

	def self.model_attribute_list(name)
	    inherited_enumerable("#{name}_set", "#{name}_sets", :map => true) { Hash.new { |h, k| h[k] = ValueSet.new } }
	    class_eval <<-EOD
		def self.each_#{name}(model)
		    for obj in #{name}s(model)
			yield(obj)
		    end
		    self
		end
		def self.#{name}s(model)
		    result = ValueSet.new
		    each_#{name}_set(model, false) do |set|
			result.merge set
		    end
		    result
		end
		def each_#{name}(model); self.model.each_#{name}(model) { |o| yield(o) } end
	    EOD
	end

	attr_reader :model

	model_attribute_list('signal')
	model_attribute_list('forwarding')
	model_attribute_list('causal_link')
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
	
	# This predicate is true if this task is a mission for its owners. If
	# you want to know if it a mission for the local pDB, use Plan#mission?
	attr_predicate :mission?, true

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
	    @arguments = TaskArguments.new(self)
	    @arguments.merge!(arguments) if arguments

	    @model = self.class
	    @name = "#{model.name || self.class.name}#{arguments.to_s}:0x#{address.to_s(16)}"

            yield(self) if block_given?
	    super() if defined? super

	    # Create all event generators
	    bound_events = Hash.new
	    model.each_event do |ev_symbol, ev_model|
		bound_events[ev_symbol.to_sym] = TaskEventGenerator.new(self, ev_model)
	    end
	    @bound_events = bound_events
        end

	def instantiate_model_event_relations
	    # Add the model-level signals to this instance
	    
	    for symbol, generator in bound_events
	        for signalled in model.signals(symbol)
	            generator.signal bound_events[signalled]
	        end

	        for signalled in model.forwardings(symbol)
	            generator.forward bound_events[signalled]
	        end

	        for signalled in model.causal_links(symbol)
	            generator.add_causal_link bound_events[signalled]
	        end
	    end

	    start_event = bound_events[:start]
	    for symbol, generator in bound_events
	        if symbol != :start
	            start_event.add_precedence(generator)
	        end
	    end

	    @instantiated_model_events = true
	    update_terminal_flag

	    # WARN: the start event CAN be terminal: it can be a signal from
	    # :start to a terminal event
	    #
	    # Create the precedence relations between 'normal' events and the terminal events
	    for terminal in terminal_events
	        next if terminal.symbol == :start
	        for _, generator in bound_events
	            unless generator.terminal?
	        	generator.add_precedence(terminal)
	            end
	        end
	    end
	end

	def plan=(new_plan)
	    if plan != new_plan
		if plan && plan.include?(self)
		    raise TaskModelViolation.new(self), "still included in #{plan}, cannot change the plan"
		elsif self_owned? && running?
		    raise TaskModelViolation.new(self), "cannot change the plan of a running task"
		end
	    end

	    old_plan = plan
	    super

	    if !old_plan && new_plan
		# First time we get included in a plan, instantiate all relations
		instantiate_model_event_relations
	    end

	    for _, ev in bound_events
		ev.plan = plan
	    end
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
		event(:stop) do |context| 
		    if starting?
			on :start, self, :stop
			return
		    end
		    failed!(context)
		end
	    end
	    def polls
		if !instance_method?(:poll)
		    raise ArgumentError, "#{self} does not define a 'poll' instance method"
		end
		poll(&method(:poll))
	    end

	    def setup_poll_method(block)
		define_method(:poll) do
		    begin
			poll_handler
		    rescue Exception => e
			emit :failed, e
		    end
		end

		define_method(:poll_handler, &block)
	    end

	    def poll(&block)
		if !block_given?
		    raise "no block given"
		end

		setup_poll_method(block)

		on(:start) { Control.event_processing << method(:poll) }
		on(:stop)  { Control.event_processing.delete(method(:poll)) }
	    end
	end

	# Roby::Task is an abstract model
	abstract

	def abstract?; self.class.abstract? end
	# Check if this task is executable
	def executable?; !abstract? && !partially_instanciated? && super end
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
	def fully_instanciated?
	    @fully_instanciated ||= model.arguments.all? { |name| arguments.has_key?(name) }
	end
	# Returns true if one argument required by the task model is not set
	def partially_instanciated?; !fully_instanciated? end

        # If a model of +event+ is defined in the task model
        def has_event?(event); model.has_event?(event) end
        
	def starting?; event(:start).pending? end
	# If this task never ran
	def pending?; !starting? && !started? end
        # If this task is currently running
        def running?; started? && !finished? end
	# A terminal event that has already happened. nil if the task
	# is not finished
	def finishing?
	    if running?
		each_event { |ev| return true if ev.terminal? && ev.pending? }
	    end
	    false
	end

        # If this task ran and is finished
	attr_predicate :started?, true
	attr_predicate :finished?, true
	attr_predicate :success?, true
	def failed?; finished? && @success == false end

	# Remove all relations in which +self+ or its event are involved
	def clear_relations
	    each_event { |ev| ev.clear_relations }
	    super
	end

	# Update the terminal flag for the event models that are defined in
	# this task model. The event is terminal if model-level signals (set up
	# by Task::on) lead to the emission of the +stop+ event
	def self.update_terminal_flag # :nodoc:
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

	# Updates the terminal flag for all events in the task. An event is
	# terminal if the +stop+ event of the task will be called because this
	# event is.
	def update_terminal_flag
	    return unless @instantiated_model_events

	    for _, ev in bound_events
		ev.terminal_flag = nil
	    end
	    success_events = bound_events[:success].
		generated_subgraph(EventStructure::CausalLink.reverse)
	    failure_events = bound_events[:failed].
		generated_subgraph(EventStructure::CausalLink.reverse)
	    terminal_events = bound_events[:stop].
		generated_subgraph(EventStructure::CausalLink.reverse)

	    if success_events.intersects?(failure_events)
		raise ArgumentError, "#{success_events & failure_events} are both success and failure events"
	    end

	    for ev in success_events
		ev.terminal_flag = :success if ev.respond_to?(:task) && ev.task == self
	    end
	    for ev in failure_events
		ev.terminal_flag = :failure if ev.respond_to?(:task) && ev.task == self
	    end
	    for ev in (terminal_events - success_events - failure_events)
		ev.terminal_flag = true if ev.respond_to?(:task) && ev.task == self
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
	    each_event do |ev|
		ev.related_tasks(result)
	    end

	    result
	end
	def related_events(result = nil)
	    each_event do |ev|
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

            if finished? && !event.terminal?
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} by #{Propagation.sources} but the task has finished"
            elsif pending? && event.symbol != :start
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} by #{Propagation.sources} but the task is not running"
            elsif running? && event.symbol == :start
                raise TaskModelViolation.new(self), "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} by #{Propagation.sources} but the task is already running"
            end

	    update_task_status(event)

	    super if defined? super
        end

	# The event which has finished the task
	attr_reader :terminal_event
	
	# Call to update the task status because of +event+
	def update_task_status(event)
	    if event.success?
		self.success = true
		self.finished = true
		@terminal_event ||= event
	    elsif event.failure?
		self.success = false
		self.finished = true
		@terminal_event ||= event
	    elsif event.terminal?
		self.finished = true
		@terminal_event ||= event
	    end
	    
	    if event.symbol == :start
		self.started = true
	    end
	end
        
	# List of EventGenerator objects bound to this task
        attr_reader :bound_events

        # call-seq:
        #   emit(event_model, *context)                       event object
        #
        # Emits +event_model+ in the given +context+. Event handlers are fired.
        # This is equivalent to
        #   event(event_model).emit(*context)
        #
        def emit(event_model, *context)
            event(event_model).emit(*context)
            self
        end

        # Returns an TaskEventGenerator object which is the given task event bound
        # to this particular task
        def event(event_model)
	    unless event = bound_events[event_model]
		event_model = self.event_model(event_model)
		unless event = bound_events[event_model.symbol]
		    raise "cannot find #{event_model.symbol.inspect} in the set of bound events in #{self}. Known events are #{bound_events}."
		end
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
        def on(event_model, to = nil, *to_task_events, &user_handler)
            unless to || user_handler
                raise ArgumentError, "you must provide either a task or an event handler"
            end

            generator = event(event_model)
	    to_events = case to
			when Task
			    if to_task_events.empty?
				[to.event(generator.symbol)]
			    else
				to_task_events.map { |ev_model| to.event(ev_model) }
			    end
			when EventGenerator: [to]
			else []
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
	def forward(event_model, to, *to_task_events)
            generator = event(event_model)
	    to_events = case to
			when Task
			    if to_task_events.empty?
				[to.event(generator.symbol)]
			    else
				to_task_events.map { |ev| to.event(ev) }
			    end
			when EventGenerator
			    [to]
			else
			    raise ArgumentError, "expected Task or EventGenerator, got #{to}(#{to.class}: #{to.class.ancestors})"
			end

	    to_events.each do |ev|
		generator.forward ev
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

            ev_s = ev.to_s
            ev = ev.to_sym

            if !options.has_key?(:command)
		if block
		    define_method("event_command_#{ev_s}", &block)
		    method = instance_method("event_command_#{ev_s}")
		elsif method_defined?(ev_s)
		    method = instance_method(ev)
		end

		if method
		    check_arity(method, 1)
		    options[:command] = lambda do |dst_task, *event_context| 
			begin
			    dst_task.calling_event = dst_task.event(ev)
			    method.bind(dst_task).call(*event_context) 
			ensure
			    dst_task.calling_event = nil
			end
		    end
		end
            end
            validate_event_definition_request(ev, options)

            command_handler = options[:command] if options[:command].respond_to?(:call)
            
            # Define the event class
	    task_klass = self
            new_event = Class.new(options[:model]) do
		@terminal = options[:terminal]
                @symbol   = ev
                @command_handler = command_handler

		define_method(:name) { "#{task.name}::#{ev_s.camelize}" }
                singleton_class.class_eval do
                    attr_reader :command_handler
		    define_method(:name) { "#{task_klass.name}::#{ev_s.camelize}" }
		    def to_s; name end
                end
            end

	    setup_terminal_handler = false
	    old_model = find_event_model(ev)
	    if new_event.symbol != :stop && options[:terminal] && (!old_model || !old_model.terminal?)
		setup_terminal_handler = true
	    end

	    events[new_event.symbol] = new_event
	    if setup_terminal_handler
		forward(new_event => :stop)
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
			    task.emit(symbol, *context)
			end
		    end
                end

		# define an instance method which calls the event command
		define_method("#{ev_s}!") do |*context| 
		    begin
			generator = event(ev)
			generator.call(*context) 
		    rescue EventNotExecutable => e
			if partially_instanciated?
			    raise EventNotExecutable.new(generator), "#{ev_s}! called on #{generator.task} which is partially instanciated"
			elsif !plan
			    raise EventNotExecutable.new(generator), "#{ev_s}! called on #{generator.task} but the task is in no plan"
			elsif !plan.executable?
			    raise EventNotExecutable.new(generator), "#{ev_s}! called on #{generator.task} but the plan is not executable"
			elsif abstract?
			    raise EventNotExecutable.new(generator), "#{ev_s}! called on #{generator.task} but the task is abstract"
			else
			    raise EventNotExecutable.new(generator), "#{ev_s}! called on #{generator.task} which is not executable: #{e.message}"
			end
		    end
		end
            end

	    new_event
        end

        def self.validate_event_definition_request(ev, options) #:nodoc:
            if options[:command] && options[:command] != true && !options[:command].respond_to?(:call)
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
	def self.enum_events
	    @__enum_events__ ||= enum_for(:each_event)
	end

        # Iterates on all the events defined for this task
        def each_event # :yield:bound_event
	    for _, ev in bound_events
		yield(ev)
	    end
        end
	alias :each_plan_child :each_event

	def terminal_events
	    bound_events.values.find_all { |ev| ev.terminal? }
	end

        # Get the list of terminal events for this task model
        def self.terminal_events
	    enum_events.find_all { |_, e| e.terminal? }.
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
		    all_events = enum_events.map { |name, _| name }
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
                to = if to
			 Array[*to].map do |ev| 
			     model = event_model(ev)
			     raise "trying to signal #{ev} which is not controlable" unless model.controlable?
			     model.symbol
			 end
                     else;  []
                     end

		signal_sets[from].merge to.to_value_set
		update_terminal_flag

		if user_handler 
		    method_name = "event_handler_#{from}_#{Object.address_from_id(user_handler.object_id).to_s(16)}"
		    define_method(method_name, &user_handler)
		    handler_sets[from] << lambda { |event| event.task.send(method_name, event) }
		end
            end
        end

	# call-seq:
	#   causal_link(:from => :to)
	#
	# Declares a causal link between two events in the task
	def self.causal_link(mappings)
            mappings.each do |from, to|
                from = event_model(from).symbol
		causal_link_sets[from].merge Array[*to].map { |ev| event_model(ev).symbol }.to_value_set
            end
	    update_terminal_flag
	end

	# +mappings+ is a from => to hash where +from+ is forwarded to +to+.
	def self.forward(mappings)
            mappings.each do |from, to|
                from = event_model(from).symbol
		forwarding_sets[from].merge Array[*to].map { |ev| event_model(ev).symbol }.to_value_set
            end
	    update_terminal_flag
	end

	def self.precondition(event, reason, &block)
	    event = event_model(event)
	    precondition_sets[event.symbol] << [reason, block]
	end

        def to_s
	    s = name.dup
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
	def pretty_print(pp)
	    pp.text to_s
	    pp.group(2, ' {', '}') do
		pp.breakable
		pp.text "owners: "
		pp.seplist(owners) { |r| pp.text r.to_s }

		pp.breakable
		pp.text "relations: "
		pp.seplist(relations) { |r| pp.text r.name }

		pp.breakable
		pp.text "arguments: "
		pp.pp arguments
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
	forward :aborted => :failed

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
		klass, args = 
		    models.class, 
		    models.meaningful_arguments
		models = [klass]
	    else
		models = [*models]
	    end
	    self_model = self.model
	    self_args  = self.arguments
	    args       = args.dup

	    # Check the arguments that are required by the model
	    for tag in models
		unless self_model.has_ancestor?(tag)
		    return false
		end

		unless args.empty?
		    for arg_name in tag.arguments
			if user_arg = args.delete(arg_name)
			    return false unless user_arg == self_args[arg_name]
			end
			break if args.empty?
		    end
		end
	    end

	    if !args.empty?
		raise ArgumentError, "the arguments '#{args.keys.join(", ")}' are unknown to the tags #{models.join(", ")}"
	    end
	    true
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
	
	# We can't add relations on objects we don't own
	def add_child_object(child, type, info)
	    unless read_write? && child.read_write?
	        raise NotOwner, "cannot add a relation between tasks we don't own.  #{self} by #{owners.to_a} and #{child} is owned by #{child.owners.to_a}"
	    end

	    super
	end

	def replace_subplan_by(object)
	    super

	    # Compute the set of tasks that are in our subtree and not in
	    # object's *after* the replacement
	    own_subtree = ValueSet.new
	    TaskStructure.each_root_relation do |rel|
		own_subtree.merge generated_subgraph(rel)
		own_subtree -= object.generated_subgraph(rel)
	    end

	    changes = []
	    each_event do |event|
		next unless object.has_event?(event.symbol)
		changes.clear

		event.each_relation do |rel|
		    parents = []
		    event.each_parent_object(rel) do |parent|
			if !parent.respond_to?(:task) || !own_subtree.include?(parent.task)
			    parents << parent << parent[event, rel]
			end
		    end
		    children = []
		    event.each_child_object(rel) do |child|
			if !child.respond_to?(:task) || !own_subtree.include?(child.task)
			    children << child << event[child, rel]
			end
		    end
		    changes << rel << parents << children
		end

		event.apply_relation_changes(object.event(event.symbol), changes)
	    end
	end

	def replace_by(object)
	    each_event do |event|
		event_name = event.symbol
		if object.has_event?(event_name)
		    event.replace_by object.event(event_name)
		end
	    end
	    super
	end

	def poll(&block)
	    if !pending?
		raise ArgumentError, "cannot set a polling block when the task is not pending"
	    end

	    
	    singleton_class.class_eval do
		setup_poll_method(block)
	    end
	    on(:start) { Control.event_processing << method(:poll) }
	    on(:stop)  { Control.event_processing.delete(method(:poll)) }
	end
    end

    class NullTask < Task
        event :start, :command => true
        event :stop
        forward :start => :stop

        def null?; true end
    end

    unless defined? TaskStructure
	TaskStructure   = RelationSpace(Task)
    end
end

require 'roby/task-operations'

