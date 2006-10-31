require 'roby/task'

module Roby::TaskStructure
    relation :PlannedBy, :child_name => :planning_task, :parent_name => :planned_task, :noinfo => true do
	def planned_task; enum_for(:each_planned_task).find { true } end
	def planned_tasks; enum_for(:each_planned_task) end
	def planning_task; enum_for(:each_planning_task).find { true } end
        def planned_by(task)
            raise TaskModelViolation.new(self), "this task already has a planner" if planning_task
	    add_planning_task(task)
        end
    end
end

