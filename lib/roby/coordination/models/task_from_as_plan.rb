# frozen_string_literal: true

module Roby
    module Coordination
        module Models
            # Definition of a state from an object that responds to instanciate
            class TaskFromAsPlan < TaskWithDependencies
                # @return [#instanciate] the object that will be used to generate
                #   the state's task when needed
                attr_reader :instanciation_object

                # @param [#instanciate] instanciation_object this object will be
                #   used to generate the task that will perform the state's action.
                #   It will be called with #instanciate(plan)
                # @param [Model<Roby::Task>] task_model the model of the task
                #   returned by the instanciation object
                def initialize(instanciation_object, task_model)
                    super(task_model)
                    @instanciation_object = instanciation_object
                end

                # Called by the state machine implementation to create a Roby::Task
                # instance that will perform the state's actions
                def instanciate(plan, variables = {})
                    plan.add(task = instanciation_object.as_plan)
                    task
                end

                def to_s
                    "#{instanciation_object}[#{model}]"
                end
            end
        end
    end
end
