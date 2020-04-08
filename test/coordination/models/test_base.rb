# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Coordination
        module Models
            describe Base do
                attr_reader :base_m
                before do
                    @base_m = Class.new
                    base_m.extend Models::Base
                    task_m = Roby::Task.new_submodel
                    base_m.root task_m
                end

                it "rebinds the root task in submodels" do
                    submodel_m = base_m.new_submodel
                    refute_same base_m.root, submodel_m.root
                    assert_same submodel_m, submodel_m.root.coordination_model
                end
            end
        end
    end
end
