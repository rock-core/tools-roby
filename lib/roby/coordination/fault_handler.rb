# frozen_string_literal: true

module Roby
    module Coordination
        class FaultHandler < ActionScript
            extend Models::FaultHandler

            def step
                super

                return unless finished?
                return unless model.carry_on?

                response_task = self.root_task
                plan = response_task.plan
                response_task.each_parent_object(Roby::TaskStructure::ErrorHandling) do |repaired_task|
                    plan.replan(repaired_task)
                end
                response_task.success_event.emit
            end

            def to_s
                "#{self.class}/#{root_task}"
            end
        end
    end
end
