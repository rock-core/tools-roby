require 'roby/test/self'
require 'roby/tasks/thread'

module Roby
    module Tasks
        describe Thread do
            # Waits for the task's implementation thread to finish
            def wait_thread_end(task, exception: nil)
                if exception
                    begin task.thread.join
                    rescue exception
                    end
                else
                    task.thread.join
                end
            end

            def start_task_synchronized(one_shot: true)
                sync = Concurrent::CyclicBarrier.new(2)
                task_m = Tasks::Thread.new_submodel do
                    interruptible
                    implementation do
                        sync.wait
                        sync.wait
                        yield(self)
                    end
                end
                plan.add(task = task_m.new(one_shot: one_shot))
                expect_execution { task.start! }.
                    to { emit task.start_event }
                sync.wait
                return task, sync
            end

            it "executes the implementation in a separate thread and stores its result" do
                task, sync = start_task_synchronized { 1 }
                event = expect_execution { sync.wait }.
                    to { emit task.success_event }
                assert_equal 1, task.result
                assert_equal 1, event.context.first
            end

            it "considers a non-one_shot task that stops an error" do
                task, sync = start_task_synchronized(one_shot: false) { 1 }
                event = expect_execution { sync.wait }.
                    to { emit task.failed_event }
                assert_equal 1, event.context.first
            end

            it "emits the failed_event if the implementation thread raises" do
                error_m = Class.new(RuntimeError)
                task, sync = start_task_synchronized { raise error_m, "blaaaaaaaaah" }
                failed_event = expect_execution { sync.wait }.
                    to { emit task.failed_event }
                assert_kind_of error_m, failed_event.context.first
                assert_nil task.result
            end

            it "provides a way to declare interruption points in the threaded computation" do
                task, sync = start_task_synchronized { |task| task.interruption_point }

                expect_execution { task.stop! }.to_run
                sync.wait
                expect_execution.to { emit task.failed_event }

                assert_kind_of Interrupt, task.failed_event.last.context.first
                assert_nil task.result
            end
        end
    end
end

