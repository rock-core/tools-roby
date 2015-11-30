module Roby
    # Specialization of EventGenerator to represent task events
    #
    # It gives access to the task-specific information (associated task, event
    # name, ...)
    class TaskEventGenerator < EventGenerator
	# The task we are part of
        attr_reader :task
	# The event symbol (its name as a Symbol object)
	attr_reader :symbol
        # Changes the underlying model
        def override_model(model)
            @event_model = model
        end

        def initialize(task, model)
            @plan = task.plan
	    super(model.respond_to?(:call))
            @task, @event_model = task, model
	    @symbol = model.symbol
        end

        # The default command if the event is created with controlable: true.
        # It emits the event on the task.
	def default_command(context)
	    event_model.call(task, context)
	end

        def command=(block)
            event_model.singleton_class.class_eval do
                define_method(:call, &block)
            end
        end

	# See PlanObject::child_plan_object. 
	child_plan_object :task

	# The event plan. It is the same as task.plan and is actually updated
	# by task.plan=. It is redefined here for performance reasons.
        attr_reader :plan

	# The event plan. It is the same as task.plan and is actually updated
	# by task.plan=. It is redefined here for performance reasons.
        def plan=(plan)
            @plan = plan
            @relation_graphs = if plan then plan.event_relation_graphs
                               end
        end

	# Hook called just before the event is emitted. If it raises, the event
        # will not be emitted at all.
        #
        # This forwards the call to Task#emitting_event
        def emitting(context) # :nodoc:
            task.emitting_event(self, context)
            super if defined? super
        end

        def calling(context)
            super if defined? super
            if symbol == :start
                task.freeze_delayed_arguments
            end
        end

        def called(context)
            super if defined? super
            if terminal? && pending?
                task.finishing = true
            end
        end

        def fire(event)
            super
            if event.symbol == :start
                task.do_poll(plan)
            elsif event.symbol == :stop
                task.each_event do |ev|
                    ev.unreachable!(task.terminal_event)
                end
            end
        end

        # Actually emits the event. This should not be used directly.
        #
        # It forwards the call to Task#fire
        def fired(event) # :nodoc:
            super if defined? super
            task.fired_event(event)
        end

        # See EventGenerator#related_tasks
	def related_tasks(result = nil) # :nodoc:
	    tasks = super
	    tasks.delete(task)
	    tasks
	end

        # See EventGenerator#each_handler
	def each_handler # :nodoc:
	    if self_owned?
		task.model.each_handler(event_model.symbol) { |o| yield(o) }
	    end

	    super
	end

        # See EventGenerator#each_precondition
	def each_precondition # :nodoc:
	    task.model.each_precondition(event_model.symbol) { |o| yield(o) }
	    super
	end

        # See EventGenerator#controlable?
        def controlable? # :nodoc:
            event_model.controlable?
        end

        # Cached value for #terminal?
	attr_writer :terminal_flag # :nodoc:

        # Returns the value for #terminal_flag, updating it if needed
        def terminal_flag # :nodoc:
            if task.invalidated_terminal_flag?
                task.update_terminal_flag
            end
            return @terminal_flag
        end

        # True if this event is either forwarded to or signals the task's :stop event
	def terminal?; !!terminal_flag end
        # True if this event is either forwarded to or signals the task's :success event
	def success?; terminal_flag == :success end
        # True if this event is either forwarded to or signals the task's :failed event
	def failure?; terminal_flag == :failure end

        # Invalidates the task's terminal flag when the Forwarding and/or the
        # Signal relation gets modified.
	def added_signal(child, info) # :nodoc:
	    super
            invalidate_task_terminal_flag_if_needed(child)
        end

        def invalidate_task_terminal_flag_if_needed(child)
            if child.respond_to?(:task) && child.task == task
                task.invalidate_terminal_flag
            end
        end

        # Invalidates the task's terminal flag when the Forwarding and/or the
        # Signal relation gets modified.
	def added_forwarding(child, info) # :nodoc:
	    super
            invalidate_task_terminal_flag_if_needed(child)
	end

        # Invalidates the task's terminal flag when the Forwarding and/or the
        # Signal relation gets modified.
	def removed_signal(child)
	    super if defined? super
            invalidate_task_terminal_flag_if_needed(child)
	end

	def removed_forwarding(child)
	    super if defined? super
            invalidate_task_terminal_flag_if_needed(child)
	end

        # See EventGenerator#new
        def new(context, propagation_id = nil, time = nil) # :nodoc:
            event_model.new(task, self, propagation_id || plan.engine.propagation_id, context, time || Time.now)
        end

	def to_s # :nodoc:
	    "#{task}/#{symbol}"
	end
	def inspect # :nodoc:
	    "#{task.inspect}/#{symbol}: #{history.to_s}"
	end
        def pretty_print(pp) # :nodoc:
            pp.text "#{symbol} event of #{task.class}:0x#{task.address.to_s(16)}"
        end

        # See EventGenerator#achieve_with
	def achieve_with(obj) # :nodoc:
	    child_task, child_event = case obj
				      when Roby::Task then [obj, obj.event(:success)]
				      when Roby::TaskEventGenerator then [obj.task, obj]
				      end

	    if child_task
		unless task.depends_on?(child_task, false)
		    task.depends_on child_task, 
			success: [child_event.symbol],
			remove_when_done: true
		end
		super(child_event)
	    else
		super(obj)
	    end
	end

	# Refines exceptions that may be thrown by #call_without_propagation
        def call_without_propagation(context) # :nodoc:
            super
    	rescue EventNotExecutable => e
	    refine_call_exception(e)
        end

	# Checks that the event can be called. Raises various exception
	# when it is not the case.
	def check_call_validity # :nodoc:
            begin
                super
            rescue UnreachableEvent
            end

            if task.failed_to_start?
                raise CommandFailed.new(nil, self), 
		    "#{symbol}! called by #{plan.engine.propagation_sources.to_a} but the task has failed to start: #{task.failure_reason}"
            elsif task.event(:stop).happened?
                raise CommandFailed.new(nil, self), 
		    "#{symbol}! called by #{plan.engine.propagation_sources.to_a} but the task has finished. Task has been terminated by #{task.event(:stop).history.first.sources}."
            elsif task.finished? && !terminal?
                raise CommandFailed.new(nil, self), 
		    "#{symbol}! called by #{plan.engine.propagation_sources.to_a} but the task has finished. Task has been terminated by #{task.event(:stop).history.first.sources}."
            elsif task.pending? && symbol != :start
                raise CommandFailed.new(nil, self), 
		    "#{symbol}! called by #{plan.engine.propagation_sources.to_a} but the task has never been started"
            elsif task.running? && symbol == :start
                raise CommandFailed.new(nil, self), 
		    "#{symbol}! called by #{plan.engine.propagation_sources.to_a} but the task is already running. Task has been started by #{task.event(:start).history.first.sources}."
            end

    	rescue EventNotExecutable => e
	    refine_call_exception(e)
	end

	# Checks that the event can be emitted. Raises various exception
	# when it is not the case.
	def check_emission_validity # :nodoc:
  	    super
    	rescue EventNotExecutable => e
	    refine_emit_exception(e)
    	end

        # When an emissio and/or call exception is raised by the base
        # EventGenerator methods, this method is used to transform it to the
        # relevant task-related error.
	def refine_call_exception (e) # :nodoc:
	    if task.partially_instanciated?
		raise TaskEventNotExecutable.new(self), "#{symbol}! called on #{task} which is partially instanciated\n" + 
			"The following arguments were not set: \n" +
			task.list_unset_arguments.map {|n| "\t#{n}"}.join("\n")+"\n"
	    elsif !plan
		raise TaskEventNotExecutable.new(self), "#{symbol}! called on #{task} but the task has been removed from its plan"
	    elsif !plan.executable?
		raise TaskEventNotExecutable.new(self), "#{symbol}! called on #{task} but the plan is not executable"
	    elsif task.abstract?
		raise TaskEventNotExecutable.new(self), "#{symbol}! called on #{task} but the task is abstract"
	    else
		raise TaskEventNotExecutable.new(self), "#{symbol}! called on #{task} which is not executable: #{e.message}"
	    end
	end

        # When an emissio and/or call exception is raised by the base
        # EventGenerator methods, this method is used to transform it to the
        # relevant task-related error.
	def refine_emit_exception (e) # :nodoc:
	    if task.partially_instanciated?
		raise TaskEventNotExecutable.new(self), "emit(#{symbol}) called on #{task} which is partially instanciated\n" + 
			"The following arguments were not set: \n" +
			task.list_unset_arguments.map {|n| "\t#{n}"}.join("\n")+"\n"
	    elsif !plan
		raise TaskEventNotExecutable.new(self), "emit(#{symbol}) called on #{task} but the task is in no plan"
	    elsif !plan.executable?
		raise TaskEventNotExecutable.new(self), "emit(#{symbol}) called on #{task} but the plan is not executable"
	    elsif task.abstract?
		raise TaskEventNotExecutable.new(self), "emit(#{symbol}) called on #{task} but the task is abstract"
	    else
		raise TaskEventNotExecutable.new(self), "emit(#{symbol}) called on #{task} which is not executable: #{e.message}"
	    end
	end

        def on(options = Hash.new, &block)
            default_on_replace =
                if task.abstract? then :copy
                else :drop
                end
            on_replace, options = Kernel.filter_options options, on_replace: default_on_replace
            super(on_replace.merge(options), &block)
        end
    end
end
