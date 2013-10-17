module Roby
    module Coordination
        class FaultHandler < ActionScript
            extend Models::FaultHandler

            def step
                super
                if finished?
                    if model.try_again?
                        response_task = self.root_task
                        plan = response_task.plan
                        response_task.each_parent_object(Roby::TaskStructure::ErrorHandling) do |repaired_task|
                            plan.replan(repaired_task)
                        end
                        response_task.success_event.emit
                    elsif model.replacement
                        response_task = self.root_task
                        plan = response_task.plan
                        replacement = start_task(model.replacement)
                        response_task.each_parent_object(Roby::TaskStructure::ErrorHandling) do |repaired_task|
                            repaired_task.replace_by(replacement)
                        end
                        response_task.success_event.emit
                    end
                end
            end
        end
    end
end
