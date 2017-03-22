module Roby
    class Transaction
        # Transaction proxy for Roby::TaskEventGenerator
        module TaskEventGeneratorProxy
            proxy_for TaskEventGenerator

            def setup_proxy(object, transaction)
                super
                @task = transaction[task]
                task.bound_events[symbol] = self
            end

            # Task event generators do not have siblings on remote plan managers.
            # They are always referenced by their name and task.
            def has_sibling?(peer); false end
        end
    end
end

