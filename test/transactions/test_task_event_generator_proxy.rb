# frozen_string_literal: true

require "roby/test/self"

module Roby
    class Transaction
        describe TaskEventGeneratorProxy do
            it "does not change the state of an underlying starting task on creation" do
                # This is a regression test. We added a call to #clear_pending in
                # EventGenerator#initialize_copy, but clear_pending is meant to be
                # a hook. It is reimplemented by TaskEventGenerator, and because during
                # the transaction proxy creation TaskEventGenerator#task was still
                # pointing to the real (not proxied) task, it messed up the task state
                task_m = Roby::Task.new_submodel do
                    terminates
                    event :start do |context|
                    end
                end
                plan.add(task = task_m.new)
                execute { task.start_event.call }

                plan.in_transaction do |trsc|
                    trsc[task]
                    trsc[task.start_event]
                    assert task.starting?
                    refute task.pending?
                end
            ensure
                execute { task.start_event.emit }
            end
        end
    end
end
