module Roby::TaskStructure
    relation :PlannedBy, :child_name => :planning_task, 
	:parent_name => :planned_task, :noinfo => true, :single_child => true do

        # Returns the first child enumerated by planned_tasks. This is a
        # convenience method that can be used if it is known that the planning
        # task is only planning for one single task (a pretty common case)
        def planned_task; planned_tasks.find { true } end
	# The set of tasks which are planned by this one
	def planned_tasks; parent_objects(PlannedBy) end
	# Set +task+ as the planning task of +self+
        def planned_by(task, options = {})
            options = Kernel.validate_options options,
                :replace => false, :optional => false

            allow_replace = options.delete(:replace)
	    if old = planning_task
		if allow_replace
		    remove_planning_task(old)
		else
		    raise ArgumentError, "this task already has a planner"
		end
	    end
	    add_planning_task(task, options)
        end
    end

    # Returns a set of PlanningFailedError exceptions for all abstract tasks
    # for which planning has failed
    def PlannedBy.check_structure(plan)
	result = []
	PlannedBy.each_edge do |planned_task, planning_task, options|
	    next if plan != planning_task.plan
            next if !planning_task.failed?
            next if !planned_task.self_owned?

	    if (planned_task.pending? && !planned_task.executable?) || !options[:optional]
                result << Roby::PlanningFailedError.new(planned_task, planning_task)
            end
	end

	result
    end
end

module Roby
    # This exception is raised when a task is abstract, and its planner failed:
    # the system will therefore not have a suitable executable development for
    # this task, and this is a failure
    class PlanningFailedError < LocalizedError
	# The planning task
	attr_reader :planned_task

	def initialize(planned_task, planning_task)
	    @planned_task = planned_task
	    super(planning_task.failure_event || planning_task)
	end
        def pretty_print(pp)
            pp.text "failed to plan "
            planned_task.pretty_print(pp)
            pp.breakable
            pp.breakable

            failed_task.pretty_print(pp)
            pp.text " failed with "
            failed_task.failure_reason.pretty_print(pp)
            pp.breakable
            if failed_task.failure_reason.kind_of?(Exception)
                pp_exception(pp, failed_task.failure_reason)
            end
        end
    end
end

