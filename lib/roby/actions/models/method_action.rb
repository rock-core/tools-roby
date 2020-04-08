# frozen_string_literal: true

module Roby
    module Actions
        module Models
            # Action defined by a method on an {Interface}
            class MethodAction < Action
                # Exception raised when a method-action returns a task that does not
                # match its declared return type
                class InvalidReturnedType < RuntimeError
                    def initialize(action_interface_model, method_name,
                        returned_task, expected_type)
                        @action_interface_model = action_interface_model
                        @method_name = method_name
                        @returned_task = returned_task
                        @expected_type = expected_type
                    end

                    def pretty_print(pp)
                        pp.text "action '#{@action_interface_model.name}.#{@method_name}'"
                        pp.text " was expected to return"
                        pp.breakable
                        pp.text "a task of type "
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
                    arguments = arguments.transform_keys(&:to_sym)
                    detect_unknown_arguments(arguments)
                    required_and_default_arguments(arguments)

                    action_interface = action_interface_model.new(plan)
                    result =
                        if self.arguments.empty?
                            action_interface.send(name)
                        else
                            action_interface.send(name, **arguments)
                        end

                    result = validate_returned_task_type(result)
                    plan.add(result)

                    # Make the planning task inherit the model/argument flags
                    update_planning_task(result)
                    result
                end

                def detect_unknown_arguments(arguments)
                    known_arguments = self.arguments.map(&:name).map(&:to_sym)
                    invalid_arg = arguments
                                  .each_key.find { |k| !known_arguments.include?(k) }
                    return unless invalid_arg

                    expected_arguments =
                        if known_arguments.empty?
                            "The action accepts no arguments"
                        else
                            "The action accepts the following arguments: "\
                            "#{known_arguments.sort.join(', ')}"
                        end

                    raise ArgumentError,
                          "unknown argument '#{invalid_arg}' given to action #{self}. "\
                          "#{expected_arguments}"
                end

                def required_and_default_arguments(arguments)
                    self.arguments.each do |arg|
                        arg_sym = arg.name.to_sym
                        next if arguments.key?(arg_sym)

                        if arg.required
                            raise ArgumentError,
                                  "required argument '#{arg.name}' not given to action "\
                                  "#{self}"
                        elsif arg.default
                            arguments[arg_sym] = arg.default
                        end
                    end
                end

                def validate_returned_task_type(result)
                    result = result.as_plan
                    return result if result.fullfills?(returned_task_type)

                    e = InvalidReturnedType.new(
                        action_interface_model, name, result, returned_task_type
                    )

                    raise e, "action '#{self}' was expected to return a task of "\
                             "type #{returned_task_type}, but returned #{result}"
                end

                def update_planning_task(result)
                    return unless (planning_task = result.planning_task)

                    if planning_task.respond_to?(:action_model=)
                        planning_task.action_model ||= self
                    end
                    if planning_task.respond_to?(:action_arguments=)
                        planning_task.action_arguments ||= arguments
                    end
                    nil
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
                             action_arguments: arguments].merge(job_id)
                    )
                    planner.planning_result_task
                end

                def to_s
                    "#{action_interface_model.name}.#{name}"
                end
            end
        end
    end
end
