require 'roby/task'

module Roby::TaskStructure
    relation PlannedBy do
	relation_name :planning_task

	def planning_task; enum_for(:each_planning_task).find { true } end
        def planned_by(task)
            raise TaskModelViolation.new(self), "this task already has a planner" if planning_task
	    add_planning_task(task)
        end
    end
end

