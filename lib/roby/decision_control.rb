module Roby
    class DecisionControl
	def conflict(starting_task, running_tasks)
	    for t in running_tasks
		starting_task.event(:start).postpone t.event(:stop)
		return
	    end
	end
    end

    class << self
	attr_reader :decision_control
    end

    @decision_control = DecisionControl.new
end

