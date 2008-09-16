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

	# Returns the set of events from the task that are the cause of this
	# event
	def task_sources
	    result = ValueSet.new
	    event_sources = sources
            for ev in event_sources
                gen = ev.generator
                if gen.respond_to?(:task) && gen.task == task
                    result.merge ev.task_sources
                end
            end
	    if result.empty?
		result << self
	    end

	    result
	end

	def to_s
	    "#{generator.to_s}@#{propagation_id} [#{time.to_hms}]: #{context}"
	end

        def pretty_print(pp)
            pp.text "at [#{time.to_hms}/#{propagation_id}] in the "
            generator.pretty_print(pp)
            pp.breakable
            pp.group(2) do
                pp.seplist(context || []) { |v| v.pretty_print pp }
            end
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

	# See EventGenerator#calling
	#
	# In TaskEventGenerator, this hook checks that the task is running
	def calling(context)
	    super if defined? super
            if task.finished? && !terminal?
                raise CommandFailed.new(nil, self), 
		    "#{symbol}!(#{context})) called by #{plan.engine.propagation_sources} but the task has finished. Task has been terminated by #{task.event(:stop).history.first.sources}."
            elsif task.pending? && symbol != :start
                raise CommandFailed.new(nil, self), 
		    "#{symbol}!(#{context})) called by #{plan.engine.propagation_sources} but the task is not running"
            elsif task.running? && symbol == :start
                raise CommandFailed.new(nil, self), 
		    "#{symbol}!(#{context})) called by #{plan.engine.propagation_sources} but the task is already running. Task has been started by #{task.event(:start).history.first.sources}."
            end
	end

	# See EventGenerator#fired
	#
	# In TaskEventGenerator, this hook calls the unreachable handlers added
	# by EventGenerator#if_unreachable when the task has finished, not
	# before
	def fired(event)
	    super if defined? super
	    
	    if symbol == :stop
		task.each_event { |ev| ev.unreachable!(task.terminal_event) }
	    end
	end

	def related_tasks(result = nil)
	    tasks = super
	    tasks.delete(task)
	    tasks
	end

	def each_handler
	    super

	    if self_owned?
		task.each_handler(event_model.symbol) { |o| yield(o) }
	    end
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
	def added_child_object(child, relations, info)
	    super if defined? super

	    if relations.include?(EventStructure::CausalLink) && 
		child.respond_to?(:task) && child.task == task &&
		    child.terminal_flag != terminal_flag

		task.update_terminal_flag
	    end
	end
	def removed_child_object(child, relations)
	    super if defined? super

	    if relations.include?(EventStructure::CausalLink) &&
		child.respond_to?(:task) && child.task == task &&
		    terminal_flag

		task.update_terminal_flag
	    end
	end
        def new(context); event_model.new(task, self, plan.engine.propagation_id, context) end

	def to_s
	    "#{task}/#{symbol}"
	end
	def inspect
	    "#{task.inspect}/#{symbol}: #{history.to_s}"
	end
        def pretty_print(pp)
            pp.text "#{symbol} event of #{task.class}:0x#{task.address.to_s(16)}"
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

	# Checks that the event can be called. Raises various exception
	# when it is not the case.
	def check_call_validity
  	    super
    	rescue EventNotExecutable => e
	    refine_exception(e)
	end

	# Checks that the event can be emitted. Raises various exception
	# when it is not the case.
	def check_emission_validity
  	    super
    	rescue EventNotExecutable => e
	    refine_exception(e)
    	end


	def refine_exception (e)
	    if task.partially_instanciated?
		raise EventNotExecutable.new(self), "#{name}! called on #{task} which is partially instanciated\n" + 
			"The following arguments were not set: \n" +
			task.list_unset_arguments.map {|n| "\t#{n}"}.join("\n")+"\n"
# 						
	    elsif !plan
		raise EventNotExecutable.new(self), "#{name}! called on #{task} but the task is in no plan"
	    elsif !plan.executable?
		raise EventNotExecutable.new(self), "#{name}! called on #{task} but the plan is not executable"
	    elsif task.abstract?
		raise EventNotExecutable.new(self), "#{name}! called on #{task} but the task is abstract"
	    else
		raise EventNotExecutable.new(self), "#{name}! called on #{task} which is not executable: #{e.message}"
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

	alias :update! :[]=
	def []=(key, value)
	    if writable?(key)
		if !task.read_write?
		    raise OwnershipError, "cannot change the argument set of a task which is not owned #{task} is owned by #{task.owners} and #{task.plan} by #{task.plan.owners}"
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

	alias :do_merge! :merge!
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
	unless defined? RootTaskTag
	    RootTaskTag = TaskModelTag.new
	    include RootTaskTag
	end

        # Clears all definitions saved in this model. This is to be used by the
        # reloading code
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
	def name
	    @name ||= "#{model.name || self.class.name}#{arguments.to_s}:0x#{address.to_s(16)}"
	end
	
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
	    super() if defined? super

	    @arguments = TaskArguments.new(self)
	    @arguments.merge!(arguments) if arguments

	    @model = self.class

            yield(self) if block_given?
	    initialize_events
	end


        # Lists all arguments, that are set to be needed via the :argument 
        # syntax but are not set.
        # This is needed for debugging purposes.
        def list_unset_arguments
            ret = Array.new
            model.arguments.each { |name| 
                  if !arguments.has_key?(name) then 
                     ret << name
                  end }
            ret
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

	def model; self.class end

	def initialize_copy(old) # :nodoc:
	    super

	    @name = nil
	    @history = old.history.dup

	    @arguments = TaskArguments.new(self)
	    arguments.do_merge! old.arguments
	    arguments.instance_variable_set(:@task, self)

	    initialize_events
	    plan.discover(self)
	end

	def instantiate_model_event_relations
	    return if @instantiated_model_events
	    # Add the model-level signals to this instance
	    @instantiated_model_events = true
	    
	    left_border = bound_events.values.to_value_set
	    right_border = bound_events.values.to_value_set

	    model.each_signal_set do |generator, signalled_events|
		next if signalled_events.empty?
	        generator = bound_events[generator]
	        right_border.delete(generator)

	        for signalled in signalled_events
	            signalled = bound_events[signalled]
	            generator.signal signalled
	            left_border.delete(signalled)
	        end
	    end


	    model.each_forwarding_set do |generator, signalled_events|
		next if signalled_events.empty?
	        generator = bound_events[generator]
	        right_border.delete(generator)

	        for signalled in signalled_events
	            signalled = bound_events[signalled]
	            generator.forward signalled
	            left_border.delete(signalled)
	        end
	    end

	    model.each_causal_link_set do |generator, signalled_events|
		next if signalled_events.empty?
	        generator = bound_events[generator]
	        right_border.delete(generator)

	        for signalled in signalled_events
	            signalled = bound_events[signalled]
	            generator.add_causal_link signalled
	            left_border.delete(signalled)
	        end
	    end

	    update_terminal_flag

	    # WARNING: this works only because:
	    #   * there is always at least updated_data as an intermediate event
	    #   * there is always one terminal event which is not stop
	    start_event = bound_events[:start]
	    stop_event  = bound_events[:stop]
	    left_border.delete(start_event)
	    right_border.delete(start_event)
	    left_border.delete(stop_event)
	    right_border.delete(stop_event)

	    for generator in left_border
		start_event.add_precedence(generator) unless generator.terminal?
	    end

	    # WARN: the start event CAN be terminal: it can be a signal from
	    # :start to a terminal event
	    #
	    # Create the precedence relations between 'normal' events and the terminal events
	    for terminal in left_border
		next unless terminal.terminal?
	        for generator in right_border
	            unless generator.terminal?
	        	generator.add_precedence(terminal)
	            end
	        end
	    end
	end

	def plan=(new_plan) # :nodoc:
	    if plan != new_plan
		if plan && plan.include?(self)
		    raise ModelViolation.new, "still included in #{plan}, cannot change the plan"
		elsif self_owned? && running?
		    raise ModelViolation.new, "cannot change the plan of a running task"
		end
	    end

	    super

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

            # Declare that nothing special is required to stop this task.
            # This makes +failed+ and +stop+ controlable events, and
            # makes the interruption sequence be stop! => calls failed! =>
            # emits +failed+ => emits +stop+.
	    def terminates
		event :failed, :command => true, :terminal => true
		interruptible
	    end

            # Sets up a command for +stop+ in the case where +failed+ is also
            # controllable, if the command of +failed+ should be used to stop
            # the task.
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

	    def setup_poll_method(block) # :nodoc:
		define_method(:poll) do |plan|
		    return unless self_owned?
		    begin
			poll_handler
		    rescue Exception => e
			emit :failed, e
		    end
		end

		define_method(:poll_handler, &block)
	    end

            # Defines a block which will be called at each execution cycle for
            # each running task of this model. The block is called in the
            # instance context of the target task (i.e. using instance_eval)
	    def poll(&block)
		if !block_given?
		    raise "no block given"
		end

		setup_poll_method(block)

		on(:start) { |ev| ev.task.plan.engine.propagation_handlers << method(:poll) }
		on(:stop)  { |ev| ev.task.plan.engine.propagation_handlers.delete(method(:poll)) }
	    end
	end

	# Roby::Task is an abstract model. See Task::abstract
	abstract
        
        # Returns true if this task is from an abstract model. If it is the
        # case, the task is not executable.
	def abstract?; self.class.abstract? end
	# Check if this task is executable
	def executable?; !abstract? && !partially_instanciated? && super end
	# Returns true if this task's stop event is controlable
	def interruptible?; event(:stop).controlable? end
	# Set the executable flag. executable cannot be set to +false+ if the 
	# task is running, and cannot be set to true on a finished task.
	def executable=(flag)
	    return if flag == @executable
	    return unless self_owned?
	    if flag && !pending? 
		raise ModelViolation, "cannot set the executable flag on a task which is not pending"
	    elsif !flag && running?
		raise ModelViolation, "cannot unset the executable flag on a task which is running"
	    end
	    super
	end
	
	# True if all arguments defined by Task.argument on the task model are set.
	def fully_instanciated?
	    @fully_instanciated ||= model.arguments.all? { |name| arguments.has_key?(name) }
	end
        # True if at least one argument required by the task model is not set.
        # See Task.argument.
	def partially_instanciated?; !fully_instanciated? end

        # True if this task has an event of the required model. The event model
        # can either be a event class or an event name.
        def has_event?(event_model)
	    bound_events.has_key?(event_model) ||
		self.class.has_event?(event_model)
	end
        
        # True if this task is starting, i.e. if its start event is pending
        # (has been called, but is not emitted yet)
	def starting?; event(:start).pending? end
	# True if this task has never been started
	def pending?; !starting? && !started? end
        # True if this task is currently running (i.e. is has already started,
        # and is not finished)
        def running?; started? && !finished? end
        # True if the task is finishing, i.e. if a terminal event is pending.
	def finishing?
	    if running?
		each_event { |ev| return true if ev.terminal? && ev.pending? }
	    end
	    false
	end

	attr_predicate :started?, true
	attr_predicate :finished?, true
	attr_predicate :success?, true

        # True if the +failed+ event of this task has been fired
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
	def update_terminal_flag # :nodoc:
	    return unless @instantiated_model_events

	    for _, ev in bound_events
		ev.terminal_flag = nil
	    end

            success_events, failure_events, terminal_events =
                [event(:success)].to_value_set, 
                [event(:failed)].to_value_set,
                [event(:stop), event(:success), event(:failed)].to_value_set

	    loop do
		old_size = terminal_events.size
		for _, ev in bound_events
                    for relation in [EventStructure::Signal, EventStructure::Forwarding]
                        for target in ev.child_objects(relation)
                            next if !target.respond_to?(:task) || target.task != self
                            next if ev[target, relation]

                            if success_events.include?(target)
                                success_events << ev
                                terminal_events << ev
                                break
                            elsif failure_events.include?(target)
                                failure_events << ev
                                terminal_events << ev
                                break
                            elsif terminal_events.include?(target)
                                terminal_events << ev
                            end
                        end
                    end

                    success_events.include?(ev) || failure_events.include?(ev) || terminal_events.include?(ev)
		end
		break if old_size == terminal_events.size
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

        # Returns a sorted list of Event objects, for all events that have been
        # fired by this task
	def history
	    history = []
	    each_event do |event|
		history += event.history
	    end

	    history.sort_by { |ev| ev.time }
	end

        # Returns the set of tasks directly related to this task, either
        # because of task relations or because of task events that are related
        # to other task events
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
        def fire_event(event) # :nodoc:
	    if !executable?
		raise TaskNotExecutable.new(self), "trying to fire #{event.generator.symbol} on #{self} but #{self} is not executable"
	    end

            if finished? && !event.terminal?
                raise EmissionFailed.new(nil, self), 
		    "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} by #{plan.engine.propagation_sources} but the task has finished. Task has been terminated by #{event(:stop).history.first.sources}."
            elsif pending? && event.symbol != :start
                raise EmissionFailed.new(nil, self), 
		    "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} by #{plan.engine.propagation_sources} but the task is not running"
            elsif running? && event.symbol == :start
                raise EmissionFailed.new(nil, self), 
		    "emit(#{event.symbol}: #{event.model}[#{event.context}]) called @#{event.propagation_id} by #{plan.engine.propagation_sources} but the task is already running. Task has been started by #{event(:start).history.first.sources}."
            end

	    update_task_status(event)

	    super if defined? super
        end

	# The event which has finished the task (if there is one)
	attr_reader :terminal_event
	
	# Call to update the task status because of +event+
	def update_task_status(event) # :nodoc:
	    if event.success?
		plan.task_index.set_state(self, :success?)
		self.success = true
		self.finished = true
		@terminal_event ||= event
	    elsif event.failure?
		plan.task_index.set_state(self, :failed?)
		self.success = false
		self.finished = true
		@terminal_event ||= event
	    elsif event.terminal? && !finished?
		plan.task_index.set_state(self, :finished?)
		self.finished = true
		@terminal_event ||= event
	    end
	    
	    if event.symbol == :start
		plan.task_index.set_state(self, :running?)
		self.started = true
	    end
	end
        
	# List of EventGenerator objects bound to this task
        attr_reader :bound_events

        # call-seq:
        #   emit(event_model, *context) => self
        #
        # Emits +event_model+ in the given +context+. Event handlers are fired.
        # This is equivalent to
        #   event(event_model).emit(*context)
        #
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

        # call-seq:
        #   on(event, task[, event1, event2, ...])
	#   on(event) { |event| ... }
        #   on(event[, task, event1, event2, ...]) { |event| ... }
        #   on(event, task[, event1, event2, ...], delay)
        #
        # Adds a signal from the given event to the specified targets, and/or
        # defines an event handler. Note that <tt>on(event, task)</tt> is
        # equivalent to <tt>on(event, task, event)</tt>
        #
        # +delay+, if given, specifies that the signal must be postponed for as
        # much time as specified. See EventGenerator#signal for valid values.
        def on(event_model, to = nil, *to_task_events, &user_handler)
            unless to || user_handler
                raise ArgumentError, "you must provide either a task or an event handler (got nil for both)"
            end

            generator = event(event_model)
            if Hash === to_task_events.last
                delay = to_task_events.pop
            end
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

            to_events.push delay if delay
            generator.on(*to_events, &user_handler)
            self
        end

        # call-seq:
        #   forward source_event, dest_task, ev1, ev2, ev3, ...
        #   forward source_event, dest_task, ev1, ev2, ev3, delay_options
        #
        # Fowards +name+ to the events in +to_task_events+ on task +to+.  The
        # target events will be emitted as soon as the +name+ event is emitted
        # on the receiving task, without calling any command.
        #
        # To call an event whenever other events are emitted, use the Signal
        # relation. See Task#on, Task.on and EventGenerator#on. As for Task#on,
        # <tt>forward(:start, task)</tt> is a shortcut to <tt>forward(:start,
        # task, :start)</tt>.
        #
        # If a +delay_options+ hash is provided, the forwarding is not performed
        # immediately, but with a given delay. See EventGenerator#forward for
        # the delay specification.
	def forward(name, to, *to_task_events)
            generator = event(name)
            if Hash === to_task_events.last
                delay = to_task_events.pop
            end

	    to_events = if to.respond_to?(:event)
			    if to_task_events.empty?
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
		generator.forward ev, delay
	    end
	end

	attr_accessor :calling_event
	def method_missing(name, *args, &block) # :nodoc:
	    if calling_event && calling_event.respond_to?(name)
		calling_event.send(name, *args, &block)
	    else
		super
	    end
	rescue
	    raise $!, $!.message, $!.backtrace[1..-1]
	end

	@@event_command_id = 0
	def self.allocate_event_command_id # :nodoc:
	    @@event_command_id += 1
	end
        # call-seq:
        #   self.event(name, options = nil) { ... } -> event class or nil
        #
        # Define a new event in this task. 
        #
        # ==== Available options
        #
        # <tt>command</tt>::
        #   either true, false or an event command for the new event. In that
        #   latter case, the command is an object which must respond to
        #   #to_proc. If it is true, a default handler is defined which simply
        #   emits the event. If a block is given, it is used as the event
        #   command.
        #
        # <tt>terminal</tt>::
        #   set to true if this event is a terminal event, i.e. if its emission
        #   means that the task has finished.
        #
        # <tt>model</tt>::
        #   base class for the event model (see "Event models" below). The default is the 
        #   TaskEvent class
        #
        # ==== Event models
        #
        # When a task event (for instance +start+) is emitted, a Roby::Event
        # object is created to describe the information related to this
        # emission (time, sources, context information, ...). Task.event
        # defines a specific event model MyTask::MyEvent for each task event
        # with name :my_event. This specific model is by default a subclass of
        # Roby::TaskEvent, but it is possible to override that by using the +model+
        # option.
        def self.event(ev, options = Hash.new, &block)
            options = validate_options(options, :command => nil, :terminal => nil, :model => TaskEvent)

            ev_s = ev.to_s
            ev = ev.to_sym

            if !options.has_key?(:command)
		if block
		    define_method("event_command_#{ev_s}", &block)
		    method = instance_method("event_command_#{ev_s}")
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
			def call(task, context) # :nodoc:
			    task.emit(symbol, *context)
			end
		    end
                end

		# define an instance method which calls the event command
		define_method("#{ev_s}!") do |*context| 
			generator = event(ev)
			generator.call(*context) 
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

        # Returns the set of terminal events this task has. A terminal event is
        # an event whose emission announces the end of the task. In most case,
        # it is an event which is forwarded directly on indirectly to +stop+.
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
            if user_handler
                check_arity(user_handler, 1)
            end

            mappings = [*mappings].zip([]) unless Hash === mappings
            mappings.each do |from, to|
                from = event_model(from).symbol
                to = if to
			 Array[*to].map do |ev| 
			     model = event_model(ev)
			     raise ArgumentError, "trying to signal #{ev} which is not controlable" unless model.controlable?
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
        # Declares a causal link between two events in the task. See
        # EventStructure::CausalLink for a description of the causal link
        # relation.
	def self.causal_link(mappings)
            mappings.each do |from, to|
                from = event_model(from).symbol
		causal_link_sets[from].merge Array[*to].map { |ev| event_model(ev).symbol }.to_value_set
            end
	    update_terminal_flag
	end

	# call-seq:
        #   forward :from => :to
        #
        # Defines a forwarding relation between two events of the same task
        # instance. See EventStructure::Forward for a description of the
        # forwarding relation.
        #
        # See also Task#forward and EventGenerator#forward.
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

        def to_s # :nodoc:
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

	def pretty_print(pp) # :nodoc:
	    pp.text "#{self.class.name}:0x#{self.address.to_s(16)}"
            pp.breakable
	    pp.nest(2) do
		pp.text "  owners: "
		pp.seplist(owners) { |r| pp.text r.to_s }

		pp.breakable
		pp.text "arguments: "
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

        # Returns the lists of tags this model fullfills.
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

        # Lists all exception handlers attached to this task
	def each_exception_handler(&iterator); model.each_exception_handler(&iterator) end

	@@exception_handler_id = 0

	# call-seq:
	#   on_exception(TaskModelViolation, ...) { |task, exception_object| ... }
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
	def self.on_exception(*matchers, &handler)
            check_arity(handler, 1)
	    id = (@@exception_handler_id += 1)
	    define_method("exception_handler_#{id}", &handler)
	    exception_handlers.unshift [matchers, instance_method("exception_handler_#{id}")]
	end
	
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
		if value.kind_of?(Roby::Transactions::Proxy)
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

        # Define a polling block for this task. The polling block is called at
        # each execution cycle while the task is running (i.e. in-between the
        # emission of +start+ and the emission of +stop+.
        #
        # Raises ArgumentError if the task is already running.
        #
        # See also Task::poll
	def poll(&block)
	    if !pending?
		raise ArgumentError, "cannot set a polling block when the task is not pending"
	    end

	    
	    singleton_class.class_eval do
		setup_poll_method(block)
	    end
            on(:start) { |ev| @poll_handler_id = plan.engine.add_propagation_handler(method(:poll)) }
            on(:stop)  { |ev| plan.engine.remove_propagation_handler(@poll_handler_id) }
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

	event :start do
	    event(:start).achieve_with(start_event)
	    start_event.call
	end
	on :start do
	    success_event.forward_once event(:success)
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
    end

end

