# frozen_string_literal: true

module Roby::TaskStructure
    relation :PlannedBy,
             child_name: :planning_task,
             parent_name: :planned_task,
             noinfo: true,
             single_child: true

    class PlannedBy
        module Extension
            # Returns the first child enumerated by planned_tasks. This is a
            # convenience method that can be used if it is known that the planning
            # task is only planning for one single task (a pretty common case)
            def planned_task
                each_in_neighbour_merged(PlannedBy, intrusive: true).first
            end

            # The set of tasks which are planned by this one
            def planned_tasks
                parent_objects(PlannedBy)
            end

            # Set +task+ as the planning task of +self+
            def planned_by(task, replace: false, optional: false, plan_early: true)
                if task.respond_to?(:as_plan)
                    task = task.as_plan
                end

                if old = planning_task
                    if replace
                        remove_planning_task(old)
                    else
                        raise ArgumentError, "this task already has a planner"
                    end
                end
                add_planning_task(task, optional: optional, plan_early: true)
                unless plan_early
                    task.schedule_as(self)
                end

                task
            end
        end

        # Returns a set of PlanningFailedError exceptions for all abstract tasks
        # for which planning has failed
        def check_structure(plan)
            result = []
            each_edge do |planned_task, planning_task, options|
                next if plan != planning_task.plan
                next unless planning_task.failed?
                next unless planned_task.self_owned?

                if (planned_task.pending? && !planned_task.executable?) || !options[:optional]
                    result << [Roby::PlanningFailedError.new(planned_task, planning_task), nil]
                end
            end

            result
        end
    end
end

module Roby
    # This exception is raised when a task is abstract, and its planner failed:
    # the system will therefore not have a suitable executable development for
    # this task, and this is a failure
    class PlanningFailedError < LocalizedError
        # The planning task
        attr_reader :planning_task
        # The planned task
        def planned_task
            failed_task
        end
        # The reason for the failure
        attr_reader :failure_reason

        def initialize(planned_task, planning_task, failure_reason: planning_task.failure_reason)
            super(planned_task)
            @planning_task = planning_task
            @failure_reason = failure_reason
            report_exceptions_from(failure_reason)
        end

        def pretty_print(pp)
            pp.text "failed to plan "
            planned_task.pretty_print(pp)
            pp.breakable
            pp.text "planned by "
            planning_task.pretty_print(pp)
            pp.breakable
            pp.text " failed with "
            failure_reason.pretty_print(pp)
        end
    end
end
