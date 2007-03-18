require 'roby/task'

module Roby::TaskStructure
    relation :PlannedBy, :child_name => :planning_task, :parent_name => :planned_task, :noinfo => true, :single_child => true do
	def planned_tasks; parent_objects(PlannedBy) end
        def planned_by(task)
            raise TaskModelViolation.new(self), "this task already has a planner" if planning_task
	    add_planning_task(task)
        end
    end

    def PlannedBy.check_planning(plan)
	result = []
	plan.known_tasks.each do |planned_task|
	    next unless planned_task.pending? && !planned_task.executable?
	    next unless planning_task = planned_task.planning_task
	    if planning_task.failed?
		result << Roby::PlanningFailedError.new(planned_task, planning_task)
	    end
	end

	result
    end
end

module Roby
    class PlanningFailedError < TaskModelViolation
	alias :planned_task :task
	attr_reader :planning_task, :error
	def initialize(planned_task, planning_task)
	    super(planned_task)
	    @planning_task = planning_task
	    @error = planning_task.terminal_event
	end
	def message
	    "failed to plan #{planned_task}.planned_by(#{planning_task}): failed with #{error.symbol}(#{error.context})\n#{super}"
	end
    end
    Control.structure_checks << TaskStructure::PlannedBy.method(:check_planning)
end

