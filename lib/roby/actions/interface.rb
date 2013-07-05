require 'roby/distributed/protocol'
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
            extend MetaRuby::ModelAsClass
            extend Logger::Hierarchy

            # The plan to which this action interface adds tasks
            attr_reader :plan

            def initialize(plan)
                attach_to(plan)
            end

            def attach_to(plan)
                @plan = plan
                model.fault_response_tables.each do |table_model|
                    plan.use_fault_response_table table_model
                end
            end

            def model; self.class end

            def action_state_machine(task, &block)
                model = StateMachine.new_submodel(self.model, task.model)
                model.parse(&block)
                model.new(task)
            end

            def action_script(task, &block)
                model = Script.new_submodel(self.model, task.model)
                model.parse(&block)
                model.new(task)
            end
        end
    end
end

