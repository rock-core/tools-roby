require 'roby/test/self'

module Roby
    module TaskStructure
        describe ErrorHandling do
            describe "the remove_when_done flag" do
                attr_reader :task, :repair_task

                before do
                    plan.add(@task = Tasks::Simple.new)
                    plan.add(@repair_task = Tasks::Simple.new)
                    task.start!
                    repair_task.start!
                end

                it "removes the relation when the repairing task is finished if the flag is true" do
                    task.start_event.handle_with(repair_task, remove_when_done: true)
                    repair_task.stop!
                    assert !task.child_object?(repair_task, ErrorHandling)
                end
                it "keeps the relation the relation even if the repairing task is finished if the flag is false" do
                    task.start_event.handle_with(repair_task, remove_when_done: false)
                    repair_task.stop!
                    assert task.child_object?(repair_task, ErrorHandling)
                end
                it "ignores an already finalized task" do
                    task.start_event.handle_with(repair_task, remove_when_done: true)
                    task.stop!
                    plan.remove_task(task)
                    repair_task.stop!
                end
            end
        end
    end
end

