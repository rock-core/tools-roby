require 'roby/support'
require 'roby/task/model'
require 'roby/task/event_handling'
require 'roby/task/alias'

class Task
    # Builds a task object using this task model
    # The task object can be configured by a given block. After the 
    # block is called, two things are checked:
    # * the task shall have a +begin+ event
    # * the task shall have at least one terminal event. If no +end+ event
    #   is defined, then all terminal events are aliased to +end+
    def initialize #:yields: task_object
        @history = []
        @event_handlers = Hash.new { |h, k| h[k] = Array.new }
        yield self if block_given?

        raise TaskModelViolation, "no begin event defined" unless has_event?(:begin)

        # Check that this task has at least one terminal event defined
        if model.terminal_events.empty?
            raise TaskModelViolation, "no terminal event for this task"
        elsif !model.has_event?(:end)
            # Create the end event for this class, if it not defined
            model.alias_event :end, model.terminal_events
        end

        super
    end
end

