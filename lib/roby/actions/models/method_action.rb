# frozen_string_literal: true

module Roby
    module Actions
        module Models
            # Action defined by a method on an {Interface}
            class MethodAction < Action
                class InvalidReturnedType < RuntimeError
                    def initialize(action_interface_model, method_name,
                        returned_task, expected_type)
                        @action_interface_model = action_interface_model
                        @method_name = method_name
                        @returned_task = returned_task
                        @expected_type = expected_type
                    end

                    def pretty_print(pp)
                        pp.text "method '#{@method_name}' of #{@action_interface_model}"
                        pp.breakable
                        pp.text "was expected to return a task of type "
                        @expected_type.pretty_print(pp)
                        pp.text ","
                        pp.breakable
                        pp.text "but returned "
                        @returned_task.pretty_print(pp)
                    end
                end

                # The action interface on which this action is defined
                attr_accessor :action_interface_model

                def initialize(action_interface_model, doc = nil)
                    super(doc)
                    @action_interface_model = action_interface_model
                end

                def ==(other)
                    other.kind_of?(self.class) &&
                        other.action_interface_model == action_interface_model &&
                        other.name == name
                end

                # Instanciate this action on the given plan
                def instanciate(plan, arguments = {})
                    action_interface = action_interface_model.new(plan)

                    if self.arguments.empty?
                        if !arguments.empty?
                            raise ArgumentError, "#{name} expects no arguments, but #{arguments.size} are given"
                        end

                        result = action_interface.send(name).as_plan
                    else
                        default_arguments = self.arguments.each_with_object({}) do |arg, h|
                            h[arg.name] = arg.default
                        end
                        arguments = Kernel.validate_options arguments, default_arguments
                        self.arguments.each do |arg|
                            if arg.required && !arguments.has_key?(arg.name.to_sym)
                                raise ArgumentError, "required argument #{arg.name} not given to #{name}"
                            end
                        end
                        result = action_interface.send(name, arguments).as_plan
                    end

                    unless result.fullfills?(returned_task_type)
                        raise InvalidReturnedType.new(
                            action_interface_model, name, result, returned_task_type),
                              "method '#{name}' of #{action_interface_model} was expected "\
                              "to return a task of type #{returned_task_type}, but "\
                              "returned #{result}"
                    end

                    # Make the planning task inherit the model/argument flags
                    if planning_task = result.planning_task
                        if planning_task.respond_to?(:action_model=)
                            planning_task.action_model ||= self
                        end
                        if planning_task.respond_to?(:action_arguments=)
                            result.planning_task.action_arguments ||= arguments
                        end
                    end
                    result
                end

                # Create a new action model that is bound to a different interface model
                #
                # @param [Models::Interface] action_interface_model the new model
                # @param [Boolean] force the rebind will happen only if the new
                #   interface model is a submodel of the current one. If force is
                #   true, it will be done regardless.
                # @return [Action] the rebound action model
                def rebind(action_interface_model)
                    rebound = dup
                    if action_interface_model <= self.action_interface_model
                        rebound.action_interface_model = action_interface_model
                    end
                    rebound
                end

                # Returns the plan pattern that will deploy this action on the plan
                def plan_pattern(arguments = {})
                    job_id, arguments = Kernel.filter_options arguments, :job_id

                    planner = Roby::Actions::Task.new(
                        Hash[action_model: self,
                             action_arguments: arguments].merge(job_id))
                    planner.planning_result_task
                end

                def to_s
                    "#{action_interface_model.name}.#{name}"
                end
            end
        end
    end
end
