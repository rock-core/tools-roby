# frozen_string_literal: true

module Roby
    module Coordination
        module Models
            # State whose instanciation object is provided through a state machine
            # variable
            class TaskFromVariable < TaskWithDependencies
                attr_reader :variable_name
                def initialize(variable_name, task_model)
                    @variable_name = variable_name
                    super(task_model)
                end

                def instanciate(plan, variables = {})
                    obj = variables[variable_name]
                    unless obj.respond_to?(:as_plan)
                        raise ArgumentError, "expected variable #{variable_name} to contain an object that can generate tasks, found #{obj}"
                    end

                    obj.as_plan
                end

                def to_s
                    "var(#{variable_name})[#{task_model}]"
                end
            end
        end
    end
end
