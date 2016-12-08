module Roby
    module Actions
        module Models
            # Action defined by a coordination model
            class CoordinationAction < Action
                # If this action is actually a coordination model, returns it
                #
                # @return [nil,Coordination::Models::Base]
                attr_accessor :coordination_model

                def initialize(coordination_model, doc = nil)
                    super(doc)
                    @coordination_model = coordination_model
                end

                # The underlying action interface model
                def action_interface_model
                    coordination_model.action_interface
                end

                def ==(other)
                    other.kind_of?(self.class) &&
                        other.coordination_model == coordination_model
                end

                # (see MethodAction#rebind)
                def rebind(action_interface_model)
                    rebound = dup
                    if action_interface_model < self.action_interface_model
                        rebound.coordination_model = coordination_model.
                            rebind(action_interface_model)
                    end
                    rebound
                end

                def instanciate(plan, arguments = Hash.new)
                    plan.add(root = coordination_model.task_model.new)
                    coordination_model.new(root, arguments)
                    root
                end

                # Returns the plan pattern that will deploy this action on the plan
                def plan_pattern(arguments = Hash.new)
                    job_id, arguments = Kernel.filter_options arguments, :job_id

                    planner = Roby::Actions::Task.new(
                        Hash[action_model: self,
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
                    "#{action_interface_model.name}.#{name}[#{coordination_model}]"
                end
            end
        end
    end
end

