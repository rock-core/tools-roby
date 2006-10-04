require 'roby/task'

module Roby::TaskStructure
    relation :PlannedBy, :child_name => :planning_task, :parent_name => :planned_task do
	def planned_task; enum_for(:each_planned_task).find { true } end
	def planning_task; enum_for(:each_planning_task).find { true } end
        def planned_by(task)
            raise TaskModelViolation.new(self), "this task already has a planner" if planning_task
	    add_planning_task(task)
	    plan.discover(self) if plan
        end
    end
end

