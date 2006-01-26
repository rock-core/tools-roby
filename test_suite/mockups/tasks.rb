require 'roby/task'

# We define here a set of tasks needed by unit testing
# A class that calls stop when :start is fired
class EmptyTask < Roby::Task
    event :start, :command => true
    event :stop, :terminal => true
    on :start, :stop
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
    event :a, :terminal => true
    event :b, :terminal => true
end

