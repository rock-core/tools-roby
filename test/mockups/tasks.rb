require 'roby/task'

# We define here a set of tasks needed by unit testing
if !defined?(ChoiceTask)
    class ChoiceTask < Roby::Task
        event :start do |context|
            emit :start, context
            if rand > 0.5
                emit :b
            else
                emit :a
            end
        end

        event :a
	forward a: :success
        event :b
	forward b: :success
    end

    class MultiEventTask < Roby::Task
        event :start, command: true
        event :inter
        forward start: :inter, inter: :success
    end
end

