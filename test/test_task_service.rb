# frozen_string_literal: true

require "roby/test/self"

describe Roby::TaskService do
    describe "#match" do
        it "creates an object that does not match tasks that do not provide the service" do
            srv_m = Roby::TaskService.new_submodel
            task_m = Roby::Task.new_submodel
            assert !(srv_m.match === task_m.new)
        end
        it "creates an object that can match any task that provides the service" do
            srv_m = Roby::TaskService.new_submodel
            task_m = Roby::Task.new_submodel
            task_m.provides srv_m
            assert(srv_m.match === task_m.new)
        end
    end
end
