# frozen_string_literal: true

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
                        rebound.coordination_model = coordination_model
                                                     .rebind(action_interface_model)
                    end
                    rebound
                end

                def instanciate(plan, arguments = {})
                    plan.add(root = coordination_model.task_model.new)
                    coordination_model.new(root, arguments)
                    root
                end

                None = Object.new

                # Returns the plan pattern that will deploy this action on the plan
                def plan_pattern(job_id: None, **action_arguments)
                    job_id = ({ job_id: job_id } if job_id != None)

                    arguments = {
                        action_model: self,
                        action_arguments: action_arguments
                    }.merge(job_id || {})
                    planner = Roby::Actions::Task.new(**arguments)
                    planner.planning_result_task
                end

                def to_s
                    "#{action_interface_model.name}.#{name}[#{coordination_model}]"
                end
            end
        end
    end
end
