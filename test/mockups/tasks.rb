require 'roby/task'

# We define here a set of tasks needed by unit testing
if !defined?(EmptyTask)
    # A class that calls stop when :start is fired
    class EmptyTask < Roby::Task
        event :start, :command => true
        forward :start => :success
    end

    class SimpleTask < Roby::Task
	event :start, :command => true
	event :success, :command => true, :terminal => true
	terminates
    end

    class ChoiceTask < Roby::Task
        def start(context)
            emit :start, context
            if rand > 0.5
                emit :b
            else
                emit :a
            end
        end
        event :start

        event :a
	forward :a => :success
        event :b
	forward :b => :success
    end

    class MultiEventTask < Roby::Task
        event :start, :command => true
        event :inter
        forward :start => :inter, :inter => :success
    end
end

