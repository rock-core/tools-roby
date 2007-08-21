require 'roby/task'

module Roby::TaskStructure
    relation :PlannedBy, :child_name => :planning_task, 
	:parent_name => :planned_task, :noinfo => true, :single_child => true do

	# The set of tasks which are planned by this one
	def planned_tasks; parent_objects(PlannedBy) end
	# Set +task+ as the planning task of +self+
        def planned_by(task)
            raise TaskModelViolation.new(self), "this task already has a planner" if planning_task
	    add_planning_task(task)
        end
    end

    # Returns a set of PlanningFailedError exceptions for all abstract tasks
    # for which planning has failed
    def PlannedBy.check_planning(plan)
	result = []
	Roby::TaskStructure::PlannedBy.each_edge do |planning_task, planned_task, _|
	    next unless plan == planning_task.plan && planning_task.failed?
	    next unless planned_task.pending? && !planned_task.executable? && planned_task.self_owned?
	    result << Roby::PlanningFailedError.new(planned_task, planning_task)
	end

	result
    end
end

module Roby
    # This exception is raised when a task is abstract, and its planner failed:
    # the system will therefore not have a suitable executable development for
    # this task, and this is a failure
    class PlanningFailedError < TaskModelViolation
	# The task which was planned
	alias :planned_task :task
	# The planning task
	attr_reader :planning_task
	# The planning error
	attr_reader :error

	def initialize(planned_task, planning_task)
	    super(planned_task)
	    @planning_task = planning_task
	    @error = planning_task.terminal_event
	end

	def message # :nodoc:
	    msg = "failed to plan #{planned_task}.planned_by(#{planning_task}): failed with #{error.symbol}"
	    if error.context.first.respond_to?(:full_message)
		msg << "\n" << error.context.first.full_message
	    else
		msg << "(" << error.context.first << ")"
	    end
	    msg
	end
    end
    Control.structure_checks << TaskStructure::PlannedBy.method(:check_planning)
end

