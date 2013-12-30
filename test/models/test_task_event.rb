$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/self'
require 'roby/tasks/simple'
require 'roby/test/tasks/empty_task'
require 'roby/tasks/simple'
require 'roby/tasks/group'
require 'roby/tasks/virtual'
require 'flexmock/test_unit'

describe Roby::Models::TaskEvent do
    include Roby::SelfTest

    describe "#match" do
        it "should allow matching the corresponding generator" do
            plan.add(task = Roby::Task.new)
            assert(Roby::Task.success_event.match === task.success_event)
        end
        it "should specifically match the corresponding generator" do
            plan.add(task = Roby::Task.new)
            assert !(Roby::Task.success_event.match === task.failed_event)
        end
    end

    describe "#match" do
        it "should match the corresponding generator as well as any forwarded to it" do
            plan.add(task = Roby::Task.new)
            assert(Roby::Task.stop_event.generalized_match === task.failed_event)
        end
        it "should not match generators that are forwarded from the target event" do
            plan.add(task = Roby::Task.new)
            assert !(Roby::Task.failed_event.generalized_match === task.stop_event)
        end
        it "should not match unrelated generators" do
            plan.add(task = Roby::Task.new)
            assert !(Roby::Task.failed_event.generalized_match === task.success_event)
        end
    end
end
