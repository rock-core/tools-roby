class Proc
    def to_goal_variable_model(field, name)
        check_arity(self, 1)

        result = Roby::GoalVariableModel.new(field, name)
        result.reader = self
        result
    end
end

module Roby
    # Representation of a state variable in the goal structure
    class GoalVariableModel < OpenStructModel::Variable
        # Accessor object. It must respond to #call(task) and return the state
        # variable. Note that if the associated state model defines a type, the
        # return value must be of this type
        attr_accessor :reader

        def to_goal_variable_model(field, name)
            result = dup
            result.field = field
            result.name = name
            result
        end
    end

    # Representation of a level in the state model
    class GoalModel < OpenStructModel
        def initialize(superclass = nil, attach_to = nil, attach_name = nil)
            super(superclass, attach_to, attach_name)

            global_filter do |name, value|
                if value.respond_to?(:to_goal_variable_model)
                    value.to_goal_variable_model(self, name)
                else
                    raise ArgumentError, "cannot set #{value} on #{name} in a goal model. Only allowed values are GoalVariableModel, and values that respond to #to_goal_variable_model"
                end
            end
        end

        def state_model
            model
        end

        def state_model=(value)
            @model = value
            attach_model
        end

        def create_model
            GoalModel.new
        end
    end

    # Representation of the set of goals for a task, as targets in state
    class GoalSpace < OpenStruct
        def initialize(model = nil)
            super(model)
        end
    end
end
