require 'roby/task'

# We define here a set of tasks needed by unit testing
# A class that calls stop when :start is fired
if !defined?(EmptyTask)
    # A	task that is executable event when outside a plan
    class ExecutableTask < Roby::Task
	def initialize
	    super
	    self.executable = true
	end
    end

    class EmptyTask < ExecutableTask
        event :start, :command => true
        on :start => :success
    end

    class SimpleTask < ExecutableTask
	event :start, :command => true
	event :success, :command => true, :terminal => true
	event :failed, :command => true, :terminal => true
	def stop(context)
	    failed!(context)
	end
	event :stop
    end

    class ChoiceTask < ExecutableTask
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

    class MultiEventTask < ExecutableTask
        event :start, :command => true
        event :inter
        on :start => :inter, :inter => :success
    end
end

