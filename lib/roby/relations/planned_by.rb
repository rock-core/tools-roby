require 'roby/task'

module Roby::TaskStructure
    relation :PlannedBy, :child_name => :planning_task, :parent_name => :planned_task, :noinfo => true do
	def planned_task; parent_objects(PlannedBy).find { true } end
	def planned_tasks; parent_objects(PlannedBy) end
	def planning_task; child_objects(PlannedBy).find { true } end
        def planned_by(task)
            raise TaskModelViolation.new(self), "this task already has a planner" if planning_task
	    add_planning_task(task)
        end
    end
end

