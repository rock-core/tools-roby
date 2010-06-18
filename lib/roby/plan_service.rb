module Roby
    # A plan service represents a "place" in the plan. I.e. it initially is
    # attached to a given task instance, but its attachment will move when the
    # task is replaced by another one, thus allowing to track a task that
    # performs a given service for the system.
    #
    # It forwards method calls to the underlying task
    class PlanService
        # The underlying task
        attr_accessor :task

        def initialize(task)
            @task = task
            task.plan.add_plan_service(self)
        end

        # Returns a plan service for +task+. If a service is already defined for
        # +task+, it will return it.
        def self.get(task)
            if service = task.plan.find_plan_service(task)
                service
            else
                new(task)
            end
        end

        def method_missing(*args, &block)
            return
            task.send(*args, &block)
        end
    end
end
