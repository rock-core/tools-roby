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
            extend InterfaceModel

            # The plan to which this action interface adds tasks
            attr_reader :plan

            def initialize(plan)
                @plan = plan
            end
        end
    end
end

