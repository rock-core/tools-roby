require 'roby/task'

module Roby::TaskStructure
    module PlannedBy
        attr_reader :planning_task

        def planned_by(task)
            raise TaskModelViolation.new(self), "this task already has a planner" if @planning_task
            @planning_task = task
        end
    end
end

