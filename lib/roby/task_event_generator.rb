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
            super(model.respond_to?(:call), plan: task.plan)
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
            @relation_graphs =
                if plan then plan.event_relation_graphs
                end
            @execution_engine =
                if plan && plan.executable? then plan.execution_engine
                end
        end

        def pending(sources)
            super
            if symbol == :start
                task.freeze_delayed_arguments
                plan.task_index.set_state(task, :starting?) if plan && !plan.template?
                task.pending  = false
                task.starting = true
            end
        end

        def clear_pending
            if @pending && symbol == :start
                if !emitted? && !task.failed_to_start?
                    plan.task_index.set_state(task, :pending?) if plan && !plan.template?
                    task.pending = true
                    task.starting = false
                end
            end
            super
        end

        def called(context)
            super
            if terminal? && pending?
                task.finishing = true
            end
        end

        def fire(event)
            super
            if symbol == :start
                task.do_poll(plan)
            elsif symbol == :stop
                task.each_event do |ev|
                    ev.unreachable!(task.terminal_event)
                end
            end
        end

        # Actually emits the event. This should not be used directly.
        #
        # It forwards the call to Task#fire
        def fired(event) # :nodoc:
            super
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

        # @api private
        #
        # Helper for the signal and forward relation hooks that invalidates the
        # events terminal flags when the event structure is changed
        def invalidate_task_terminal_flag_if_needed(child)
            if child.respond_to?(:task) && child.task == task
                task.invalidate_terminal_flag
            end
        end

        # Invalidates the task's terminal flag when the Forwarding and/or the
        # Signal relation gets modified.
        def added_signal(child, info) # :nodoc:
            super
            invalidate_task_terminal_flag_if_needed(child)
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
            super
            invalidate_task_terminal_flag_if_needed(child)
        end

        def removed_forwarding(child)
            super
            invalidate_task_terminal_flag_if_needed(child)
        end

        # See EventGenerator#new
        def new(context, propagation_id = nil, time = nil) # :nodoc:
            event_model.new(task, self, propagation_id || execution_engine.propagation_id, context, time || Time.now)
        end

        def to_s # :nodoc:
            "#{task}/#{symbol}"
        end
        def inspect # :nodoc:
            "#{task.inspect}/#{symbol}: #{history.to_s}"
        end
        def pretty_print(pp, context_task: nil) # :nodoc:
            pp.text "event '#{symbol}'"
            if !context_task || context_task != task
                pp.text " of"
                pp.nest(2) do
                    pp.breakable
                    task.pretty_print(pp)
                end
            end
        end

        # See EventGenerator#achieve_with
        def achieve_with(obj) # :nodoc:
            child_task, child_event = case obj
                                      when Roby::Task then [obj, obj.event(:success)]
                                      when Roby::TaskEventGenerator then [obj.task, obj]
                                      end

            if child_task
                unless task.depends_on?(child_task)
                    task.depends_on child_task, 
                        success: [child_event.symbol],
                        remove_when_done: true
                end
                super(child_event)
            else
                super(obj)
            end
        end

        def emit_failed(error = nil, message = nil)
            exception = super
            if symbol == :start
                if !task.failed_to_start?
                    task.failed_to_start!(exception)
                end
            end
        end

        # Checks that the event can be called. Raises various exception
        # when it is not the case.
        def check_call_validity # :nodoc:
            if error = super
                if !error.kind_of?(UnreachableEvent)
                    return refine_call_exception(error)
                end
            end

            if task.failed_to_start?
                CommandRejected.new(self).
                    exception("#{symbol}! called by #{execution_engine.propagation_sources.to_a} but the task has failed to start: #{task.failure_reason}")
            elsif task.event(:stop).emitted?
                CommandRejected.new(self).
                    exception("#{symbol}! called by #{execution_engine.propagation_sources.to_a} but the task has finished. Task has been terminated by #{task.event(:stop).history.first.sources.to_a}.")
            elsif task.finished? && !terminal?
                CommandRejected.new(self).
                    exception("#{symbol}! called by #{execution_engine.propagation_sources.to_a} but the task has finished. Task has been terminated by #{task.event(:stop).history.first.sources.to_a}.")
            elsif task.pending? && symbol != :start
                CommandRejected.new(self).
                    exception("#{symbol}! called by #{execution_engine.propagation_sources.to_a} but the task has never been started")
            elsif task.running? && symbol == :start
                CommandRejected.new(self).
                    exception("#{symbol}! called by #{execution_engine.propagation_sources.to_a} but the task is already running. Task has been started by #{task.event(:start).history.first.sources.to_a}.")
            else error
            end
        end

        def check_call_validity_after_calling
            if error = super
                refine_call_exception(error)
            end
        end

        # Checks that the event can be emitted. Raises various exception
        # when it is not the case.
        def check_emission_validity # :nodoc:
            if error = super
                refine_emit_exception(error)
            else
                task.check_emission_validity(self)
            end
        end

        # When an emissio and/or call exception is raised by the base
        # EventGenerator methods, this method is used to transform it to the
        # relevant task-related error.
        def refine_call_exception (e) # :nodoc:
            if task.partially_instanciated?
                TaskEventNotExecutable.new(self).
                    exception("#{symbol}_event.call on #{task} which is partially instanciated\n" + 
                        "The following arguments were not set:\n" +
                        task.list_unset_arguments.map {|n| "  #{n}"}.join("\n"))
            elsif !plan
                TaskEventNotExecutable.new(self).
                    exception("#{symbol}_event.call on #{task} but the task has been removed from its plan")
            elsif !plan.executable?
                TaskEventNotExecutable.new(self).
                    exception("#{symbol}_event.call on #{task} but its plan is not executable")
            elsif task.abstract?
                TaskEventNotExecutable.new(self).
                    exception("#{symbol}_event.call on #{task} but the task is abstract")
            elsif e.kind_of?(EventNotExecutable)
                TaskEventNotExecutable.new(self).
                    exception("#{symbol}_event.call on #{task} which is not executable")
            else e
            end
        end

        # When an emissio and/or call exception is raised by the base
        # EventGenerator methods, this method is used to transform it to the
        # relevant task-related error.
        def refine_emit_exception (e) # :nodoc:
            if task.partially_instanciated?
                TaskEventNotExecutable.new(self).
                    exception("#{symbol}_event.emit on #{task} which is partially instanciated\n" + 
                        "The following arguments were not set:\n" +
                        task.list_unset_arguments.map {|n| "  #{n}"}.join("\n"))
            elsif !plan
                TaskEventNotExecutable.new(self).
                    exception("#{symbol}_event.emit on #{task} but the task has been removed from its plan")
            elsif !plan.executable?
                TaskEventNotExecutable.new(self).
                    exception("#{symbol}_event.emit on #{task} but its plan is not executable")
            elsif task.abstract?
                TaskEventNotExecutable.new(self).
                    exception("#{symbol}_event.emit on #{task} but the task is abstract")
            elsif e.kind_of?(EventNotExecutable)
                TaskEventNotExecutable.new(self).
                    exception("#{symbol}_event.emit on #{task} which is not executable")
            else e
            end
        end

        def default_on_replace
            if task.abstract? then :copy
            else :drop
            end
        end

        def on(on_replace: default_on_replace, once: false, &block)
            super(on_replace: on_replace, once: once, &block)
        end

        def create_transaction_proxy(transaction)
            # Ensure that the task is proxied already
            transaction.wrap_task(task).event(symbol)
        end

        def match
            Queries::TaskEventGeneratorMatcher.new(task, symbol)
        end
    end
end
