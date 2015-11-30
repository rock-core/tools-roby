require 'roby/test/self'
require 'roby/tasks/virtual'

module Roby
    module Tasks
        describe Virtual do
            it "adds the task of its start event as dependency" do
                task = prepare_plan add: 1
                event = EventGenerator.new(true)
                virtual_task = Virtual.create(task.start_event, event)
                assert virtual_task.child_object?(task, TaskStructure::Dependency)
            end

            it "adds the task of its stop event as dependency" do
                task = prepare_plan add: 1
                event = EventGenerator.new(true)
                virtual_task = Virtual.create(event, task.start_event)
                assert virtual_task.child_object?(task, TaskStructure::Dependency)
            end

            describe "#create" do
                it "raises ArgumentError if the start event is not controllable" do
                    start, success = EventGenerator.new(true), EventGenerator.new
                    assert_raises(ArgumentError) { VirtualTask.create(success, start) }
                end

                it "returns a Virtual instance" do
                    start, success = EventGenerator.new(true), EventGenerator.new
                    assert_kind_of(Virtual, Virtual.create(start, success))
                end
            end

            it "tracks the progress through the provided start and success events" do
                start, success = EventGenerator.new(true), EventGenerator.new
                plan.add(task = VirtualTask.create(start, success))

                mock = flexmock do |mock|
                    mock.should_receive(:start_event).once.ordered
                    mock.should_receive(:start_task).once.ordered
                end

                start.on { |event| mock.start_event }
                task.start_event.on { |event| mock.start_task }
                task.start!
                success.emit
                assert(task.success?)
            end

            it "fails if its success event becomes unreachable" do
                start, success = EventGenerator.new(true), EventGenerator.new
                plan.add(task = VirtualTask.create(start, success))
                task.start!
                success.unreachable!
                assert task.failed?
            end

            it "fails if its success event is garbage collected" do
                start, success = EventGenerator.new(true), EventGenerator.new
                plan.add(task = VirtualTask.create(start, success))
                task.start!
                plan.remove_object(success)
                assert task.failed?
            end

            it "does nothing if the success event is emitted while the task is still pending" do
                start, success = EventGenerator.new(true), EventGenerator.new
                plan.add(success)
                plan.add(task = VirtualTask.create(start, success))
                success.emit
            end
        end
    end
end



