module Roby
    # A plan service represents a "place" in the plan. I.e. it initially is
    # attached to a given task instance, but its attachment will move when the
    # task is replaced by another one, thus allowing to track a task that
    # performs a given service for the system.
    #
    # It forwards method calls to the underlying task
    class PlanService
        # The underlying task
        #
        # @return [Roby::Task]
        attr_reader :task
        # Set of blocks that will be called when the service itself is finalized
        #
        # @see #when_finalized
        attr_reader :finalization_handlers
        # The set of event handlers that have been defined for this service
        #
        # It is a mapping from a symbol (that represents the event name) to a
        # set of procs that represent the handlers themselves
        #
        # @see #on
        attr_reader :event_handlers
        # The set of handlers for replacments
        #
        # @see #on_replacement
        attr_reader :replacement_handlers
        # The set of handlers for mission/permanent status change
        attr_reader :plan_status_handlers

        def initialize(task)
            @event_handlers = Hash.new
            @finalization_handlers = Array.new
            @replacement_handlers = Array.new
            @plan_status_handlers = Array.new
            self.task = task
            task.plan.add_plan_service(self)
        end

        def initialize_copy(source)
            super

            @event_handlers = source.event_handlers.dup
            @finalization_handlers = source.finalization_handlers.dup
            @replacement_handlers = source.replacement_handlers.dup
            @plan_status_handlers = source.plan_status_handlers.dup
        end

        # True if this plan service instance is a transaction proxy, i.e.
        # modifies an already existing service in the frame of a transaction
        def transaction_proxy?
            false
        end

        alias __to_s__ to_s
        def to_s # :nodoc:
            "#<service #{task.to_s}>"
        end

        # Register a callback that should be called when the underlying task is
        # replaced
        #
        # @yield old, new
        def on_replacement(&block)
            replacement_handlers << block
        end

        # Registers a callback that is called when the task's mission/permanent
        # status changes
        #
        # @yieldparam [Symbol] status one of :mission, :permanent or :normal
        def on_plan_status_change(&block)
            plan_status_handlers << block
            current_status =
                if task.plan.mission?(task)
                    :mission
                elsif task.plan.permanent?(task)
                    :permanent
                else :normal
                end
            block.call(current_status)
        end

        # Called to notify about a plan status change for the underlying task
        #
        # @see on_plan_status_change
        def notify_plan_status_change(new_status)
            plan_status_handlers.each do |h|
                h.call(new_status)
            end
        end

        # Change the underlying task
        def task=(new_task)
            replacement_handlers.each do |h|
                h.call(task, new_task)
            end
            @task = new_task

            # Register event handlers for all events that have a definition
            event_handlers.each_key do |event|
                new_task.event(event).on(on_replace: :drop, &method(:__handle_event__))
            end
        end

        # Event handler that is actually added to the tasks, to implement the
        # event handlers
        def __handle_event__(event) # :nodoc:
            # Only proceeed if the event's origin is the task that currently
            # represents that service
            return if event.task != task

            # And call the handlers
            event_handlers[event.generator.symbol].each do |handler|
                handler.call(event)
            end
        end

        # Called by the plan when the service is finalized
        def finalized!
            if task.plan.executable?
                finalization_handlers.each do |h|
                    h.call
                end
            end
        end

        # Defines a finalization handler for this service
        #
        # This handler will be called when the service itself is finalized
        def when_finalized(&block)
            finalization_handlers << block
        end

        # Defines an event handler for this service
        #
        # This event handler will only be called if +symbol+ is emitted by the
        # task that currently provides this service.
        #
        # For instance, if you do
        #
        #   service = PlanService.get(t)
        #   service.on(:success) do
        #       STDERR.puts "message"
        #   end
        #   plan.replace(t, t2)
        #
        # Then, before the replacement, 'message' is displayed if t emits
        # :success. After the replacement, it will be displayed if t2 emits
        # :success, and will not be displayed if t does.
        def on(event, &block)
            check_arity(block, 1)
            event = event.to_sym
            if event_handlers.has_key?(event)
                event_handlers[event] << block
            else
                task.event(event).on(on_replace: :drop, &method(:__handle_event__))
                (event_handlers[event] = Array.new) << block
            end
        end

        # Returns a plan service for +task+. If a service is already defined for
        # +task+, it will return it.
        def self.get(task)
            if service = task.plan.find_plan_service(task)
                service
            else
                new(task)
            end
        end

        def respond_to?(name, *args)
            super || task.respond_to?(name, *args)
        end

        # Forwards all calls to {task}
        def method_missing(*args, &block) # :nodoc:
            task.send(*args, &block)
        end

        # Returns the underlying task
        #
        # @see task
        def to_task
            task
        end

        def kind_of?(*args)
            super || task.kind_of?(*args)
        end
    end
end
