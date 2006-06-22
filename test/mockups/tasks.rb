require 'roby/task'

# We define here a set of tasks needed by unit testing
# A class that calls stop when :start is fired
if !defined?(EmptyTask)
    class EmptyTask < Roby::Task
        event :start, :command => true
        on :start => :success
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
	on :a => :success
        event :b
	on :b => :success
	
    end

    class MultiEventTask < Roby::Task
        event :start, :command => true
        event :inter
        on :start => :inter, :inter => :success
    end
end

