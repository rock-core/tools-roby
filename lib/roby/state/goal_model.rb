# frozen_string_literal: true

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

        def call(task)
            reader.call(task)
        end
    end

    # Representation of a level in the state model
    class GoalModel < OpenStructModel
        def initialize(state_model = nil, superclass = nil, attach_to = nil, attach_name = nil) # rubocop:disable Metrics/ParameterLists
            super(superclass, attach_to, attach_name)

            @model = state_model
            if @model
                attach_model
            end

            global_filter do |name, value|
                if value.respond_to?(:to_goal_variable_model)
                    value.to_goal_variable_model(self, name)
                else
                    raise ArgumentError,
                          "cannot set #{value} on #{name} in a goal model. Only " \
                          "allowed values are GoalVariableModel, and values that " \
                          "respond to #to_goal_variable_model"
                end
            end
        end

        def create_model
            GoalModel.new
        end

        def create_subfield(name)
            superklass = superclass&.get(name)
            supermodel = model&.get(name)
            self.class.new(supermodel, superklass, self, name)
        end

        # Once the task is completely instanciated, we should be able to
        # determine its goal
        def resolve_goals(obj, space)
            each_member do |name, value|
                if value.respond_to?(:resolve_goals)
                    value.resolve_goals(obj, space.get(name))
                else
                    space.set(name, value.call(obj))
                end
            end
        end
    end

    # Representation of the set of goals for a task, as targets in state
    class GoalSpace < OpenStruct
    end
end
