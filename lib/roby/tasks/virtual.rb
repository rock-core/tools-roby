module Roby
    module Tasks
        # A virtual task is a task representation for a combination of two events.
        # This allows to combine two unrelated events, one being the +start+ event
        # of the virtual task and the other its success event.
        #
        # The task fails if the success event becomes unreachable.
        #
        # See VirtualTask.create
        class Virtual < Task
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

            event :start do |context|
                event(:start).achieve_with(start_event)
                start_event.call
            end
            on :start do |context|
                success_event.forward_to_once event(:success)
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
    end
    # For backward-compatibility
    VirtualTask = Tasks::Virtual
end
