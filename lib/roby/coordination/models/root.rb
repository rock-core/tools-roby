module Roby
    module Coordination
        module Models
            # The root task in the execution context
            class Root < Task
                attr_accessor :coordination_model

                def initialize(model, coordination_model)
                    super(model)
                    @coordination_model = coordination_model
                end

                def rebind(coordination_model)
                    m = super
                    m.coordination_model = coordination_model
                    m
                end
            end
        end
    end
end

