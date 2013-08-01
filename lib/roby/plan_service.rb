module Roby
    # A plan service represents a "place" in the plan. I.e. it initially is
    # attached to a given task instance, but its attachment will move when the
    # task is replaced by another one, thus allowing to track a task that
    # performs a given service for the system.
    #
    # It forwards method calls to the underlying task
    class PlanService
        # The underlying task
        attr_reader :task
        # Set of blocks that will be called when the service itself is finalized
        #
        # See #when_finalized
        attr_reader :finalization_handlers
        # The set of event handlers that have been defined for this service
        #
        # It is a mapping from a symbol (that represents the event name) to a
        # set of procs that represent the handlers themselves
        #
        # See #on
        attr_reader :event_handlers
        # The set of handlers for replacments
        #
        # @see on_replacement
        attr_reader :replacement_handlers

        def initialize(task)
            @event_handlers = Hash.new
            @finalization_handlers = Array.new
            @replacement_handlers = Array.new
            self.task = task
            task.plan.add_plan_service(self)
        end

        def initialize_copy(source)
            super

            @finalization_handlers = source.finalization_handlers.dup
            @event_handlers = source.event_handlers.dup
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

        # Change the underlying task
        def task=(new_task)
            replacement_handlers.each do |h|
                h.call(task, new_task)
            end
            @task = new_task

            # Register event handlers for all events that have a definition
            event_handlers.each_key do |event|
                new_task.on(event, :on_replace => :drop, &method(:__handle_event__))
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
                task.on(event, :on_replace => :drop, &method(:__handle_event__))
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

        def method_missing(*args, &block) # :nodoc:
            task.send(*args, &block)
        end

        def to_task # :nodoc:
            task
        end

        def kind_of?(*args)
            task.kind_of?(*args)
        end
    end
end
