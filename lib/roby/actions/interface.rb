# frozen_string_literal: true

module Roby
    module Actions
        # Functionality to gather information about the actions available on a
        # given Roby app
        #
        # Actions are simply methods of arity zero or one, preceded by a call to
        # #describe. The methods can modify the current plan (available as
        # #plan) and must return the Roby::Task instance that will be used to
        # represent the action during execution
        #
        #     class Iface < Roby::Actions::Interface
        #         describe "makes the robot turn"
        #         def robot_turn
        #         end
        #     end
        class Interface
            extend Models::Interface
            extend Logger::Hierarchy

            # The plan to which this action interface adds tasks
            attr_reader :plan

            def initialize(plan)
                @plan = plan
            end

            def model
                self.class
            end

            def action_state_machine(task, &block)
                model = Coordination::ActionStateMachine
                        .new_submodel(action_interface: self.model, root: task.model)
                model.parse(&block)
                model.new(task)
            end

            def action_script(task, &block)
                model = Coordination::ActionScript
                        .new_submodel(action_interface: self.model, root: task.model)
                model.parse(&block)
                model.new(task)
            end
        end
    end
end
