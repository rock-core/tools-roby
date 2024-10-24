# frozen_string_literal: true

module Roby
    module Actions
        # The representation of an action, as a model and arguments
        class Action
            # The action model
            # @return [Models::Action]
            attr_accessor :model
            # The action arguments
            # @return [Hash]
            attr_reader :arguments

            def initialize(model, **arguments)
                @model, @arguments = model, arguments
            end

            def name
                model.name
            end

            def ==(other)
                other.kind_of?(Action) &&
                    model == other.model &&
                    arguments == other.arguments
            end

            # Update this object with new arguments and returns it
            #
            # @param [Hash] arguments new arguments
            # @return [self]
            def with_arguments(**arguments)
                @arguments = @arguments.merge(arguments)
                self
            end

            # List of required arguments that are currently not set
            #
            # @return [Array<Models::Action::Argument>]
            def missing_required_arguments
                model.arguments.find_all do |arg|
                    arg_sym = arg.name.to_sym
                    if arguments.has_key?(arg_sym)
                        TaskArguments.delayed_argument?(arguments.fetch(arg_sym))
                    else
                        arg.required?
                    end
                end
            end

            # Fill missing required arguments with example arguments when available
            def with_example_arguments
                new_args = missing_required_arguments.each_with_object({}) do |arg, h|
                    # If an argument has a default value but it received a delayed
                    # argument, then use the default value as its example
                    if !arg.required?
                        h[arg.name.to_sym] = arg.default
                    elsif arg.example_defined?
                        h[arg.name.to_sym] = arg.example
                    end
                end
                with_arguments(**new_args)
            end

            # Check whether the action model has required arguments missing
            def has_missing_required_arg?
                !missing_required_arguments.empty?
            end

            # The task model returned by this action
            def returned_type
                model.returned_type
            end

            # Returns a plan pattern that would deploy this action in the plan
            # @return [Roby::Task] the task, with a planning task of type
            #   {Actions::Task}
            def as_plan(**arguments)
                model.plan_pattern(**self.arguments.merge(arguments))
            end

            def rebind(action_interface_model)
                model.rebind(action_interface_model).new(**arguments)
            end

            # Deploys this action on the given plan
            def instanciate(plan, **arguments)
                model.instanciate(plan, **self.arguments.merge(arguments))
            end

            def to_s
                "#{model}(#{arguments.map { |k, v| "#{k} => #{v}" }.sort.join(', ')})"
            end

            def to_coordination_task(task_model = Roby::Task)
                Coordination::Models::TaskFromAction.new(self)
            end

            def to_action
                self
            end
        end
    end
end
