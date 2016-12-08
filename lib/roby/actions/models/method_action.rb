module Roby
    module Actions
        module Models
            # Action defined by a method on an {Interface}
            class MethodAction < Action
                # The action interface on which this action is defined
                attr_accessor :action_interface_model

                # If this action is actually a coordination model, returns it
                #
                # @return [nil,Coordination::Models::Base]
                attr_accessor :coordination_model

                def initialize(action_interface_model, doc = nil)
                    super(doc)

                    @action_interface_model = action_interface_model
                    @name = nil
                    @coordination_model = nil
                end
            
                def ==(other)
                    other.kind_of?(self.class) &&
                        other.action_interface_model == action_interface_model &&
                        other.name == name
                end

                # Instanciate this action on the given plan
                def instanciate(plan, arguments = Hash.new)
                    run(action_interface_model.new(plan), arguments)
                end

                # Executes the action on the given action interface
                def run(action_interface, arguments = Hash.new)
                    if self.arguments.empty?
                        if !arguments.empty?
                            raise ArgumentError, "#{name} expects no arguments, but #{arguments.size} are given"
                        end
                        result = action_interface.send(name).as_plan
                    else
                        default_arguments = self.arguments.inject(Hash.new) do |h, arg|
                            h[arg.name] = arg.default
                            h
                        end
                        arguments = Kernel.validate_options arguments, default_arguments
                        self.arguments.each do |arg|
                            if arg.required && !arguments.has_key?(arg.name.to_sym)
                                raise ArgumentError, "required argument #{arg.name} not given to #{name}"
                            end
                        end
                        result = action_interface.send(name, arguments).as_plan
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
                        if coordination_model
                            rebound.coordination_model = coordination_model.
                                rebind(action_interface_model)
                        end
                    end
                    rebound
                end

                # Returns the plan pattern that will deploy this action on the plan
                def plan_pattern(arguments = Hash.new)
                    job_id, arguments = Kernel.filter_options arguments, :job_id

                    planner = Roby::Actions::Task.new(
                        Hash[action_interface_model: action_interface_model,
                             action_model: self,
                             action_arguments: arguments].merge(job_id))
                    planner.planned_task
                end

                def proxy(peer)
                    interface_model = action_interface_model.proxy(peer)
                    if action = interface_model.find_action_by_name(name)
                        return action
                    else
                        action = super
                        action.action_interface_model = interface_model
                        action
                    end
                end

                def to_s
                    "#{action_interface_model.name}.#{name}"
                end

                # Returns the underlying coordination model
                #
                # @raise [ArgumentError] if this action is not defined by a
                #   coordination model
                # @return [Model<Coordination::Base>]
                def to_coordination_model
                    if coordination_model
                        coordination_model
                    else raise ArgumentError, "#{self} does not seem to be based on a coordination model"
                    end
                end
            end
        end
    end
end

