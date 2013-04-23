module Roby
    # Base class for events emitted by tasks.
    #
    # When one creates a new event on a task, Roby creates a corresponding
    # subclass of TaskEvent. The emitted event objects are then instances of
    # that class.
    #
    # For instance, there is a Roby::Task::StopEvent class which is used to
    # represent the emitted :stop events of Roby::Task. However, if one
    # overloads the stop command with
    #
    #   class TModel < Roby::Task
    #     event :stop, :controlable => true
    #   end
    #
    # Then TModel::StopEvent will be a subclass of StopEvent.
    #
    # These models are meant to be extended when the emission carry
    # information, i.e. to provide a robust access to the information contained
    # in Event#context
    class TaskEvent < Event
        extend Models::TaskEvent

        # The task which fired this event
        attr_reader :task
        # The event model, usually its class
        attr_reader :model

        def initialize(task, generator, propagation_id, context, time = Time.now)
            @task = task
	    @terminal_flag = generator.terminal_flag
            @model = self.class
            super(generator, propagation_id, context, time)
        end

	# Returns the events that are the cause of this event, limiting itself
        # to the task's events. The return value is a ValueSet of TaskEvent
        # instances.
        #
        # For instance, for an interruptible task:
        #
        #   task.start!
        #   task.stop!
        #
        # Then task.stop_event.last.task_sources will return a ValueSet instance
        # which contains the failed event. I.e. in this particular situation, it
        # behaves in the same way than Event#event_sources
        #
        # However, with
        #
        #   event.add_signal task.failed_event
        #   task.start!
        #   event.call
        #
        # Event#event_sources will return both event.last and
        # task.failed_event.last while TaskEvent will only return
        # task.failed_event.last.
	def task_sources
	    result = ValueSet.new
            for ev in sources
                gen = ev.generator
                if gen.respond_to?(:task) && gen.task == task
                    result << ev
                end
            end
	    result
	end

        # Recursively browses in the event sources, returning only those that
        # come from this event's task
        def all_task_sources
            result = ValueSet.new
            for ev in task_sources
                result << ev
                result.merge(ev.all_task_sources)
            end
            result
        end

        # Recursively browses in the event sources, returning those (1) that
        # come from this event's task and (2) have no parent from within the
        # Forwarding relation in the task sources.
        def root_task_sources
            all = all_task_sources
            all.find_all do |event|
                all.none? { |ev| ev.generator.child_object?(event.generator, Roby::EventStructure::Forwarding) }
            end
        end

	def to_s
	    result = "[#{Roby.format_time(time)} @#{propagation_id}] #{task}/#{symbol}"
            if context
                result += ": #{context}"
            end
            result
	end

        def pretty_print(pp)
            pp.text "[#{Roby.format_time(time)} @#{propagation_id}] #{task}/#{symbol}"
            if context
                pp.breakable
                pp.nest(2) do
                    pp.text "  "
                    pp.seplist(context) { |v| v.pretty_print(pp) }
                end
            end
        end

        # If the event is controlable
        def controlable?; model.controlable? end
	# If this event is terminal
	def success?; @terminal_flag == :success end
	# If this event is terminal
	def failure?; @terminal_flag == :failure end
	# If this event is terminal
	def terminal?; @terminal_flag end
        # The event symbol
        def symbol; model.symbol end
    end
end
