module Roby
    class Transaction
        module PlanServiceProxy
            proxy_for PlanService

            def task=(new_task)
                @task = new_task
            end

            def setup_proxy(object, plan)
                super
                finalization_handlers.clear
                event_handlers.clear
                plan_status_handlers.clear
                replacement_handlers.clear
            end

            def on_plan_status_change(&handler)
                plan_status_handlers << handler
            end

            def commit_transaction
                super

                replacement_handlers.each do |h|
                    __getobj__.on_replacement(&h)
                end
                plan_status_handlers.each do |h|
                    __getobj__.on_plan_status_change(&h)
                end
                event_handlers.each do |event, handlers|
                    handlers.each do |h|
                        __getobj__.on(event, &h)
                    end
                end
                finalization_handlers.each do |h|
                    __getobj__.when_finalized(&h)
                end
            end
        end
    end
end

