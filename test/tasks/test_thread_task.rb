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

            it "executes the implementation in a separate thread and stores its result" do
                sync = Concurrent::Event.new
                model = Roby::Tasks::Thread.new_submodel do
                    implementation do
                        sync.wait
                        1
                    end
                end

                plan.add(task = model.new)
                task.start!
                assert_event_emission task.success_event, garbage_collect: false do
                    sync.set
                end
                assert_equal 1, task.result
            end

            it "emits the failed_event if the implementation thread raises" do
                sync = Concurrent::Event.new

                error = Class.new(ArgumentError)
                model = Roby::Tasks::Thread.new_submodel do
                    implementation do
                        sync.wait
                        raise error, "blaaaaaaaaah"
                    end
                end

                plan.add(task = model.new)
                task.start!
                sync.set
                wait_thread_end(task, exception: error)
                assert_event_emission task.failed_event, garbage_collect: false

                assert task.failed?
                assert_kind_of ArgumentError, task.failed_event.last.context.first
                assert_nil task.result
            end

            it "provides a way to declare interruption points in the threaded computation" do
                sync = Concurrent::Event.new

                error = Class.new(ArgumentError)
                model = Roby::Tasks::Thread.new_submodel do
                    interruptible
                    implementation do
                        sync.wait
                        interruption_point
                    end
                end

                plan.add(task = model.new)
                task.start!
                assert_event_emission task.failed_event, garbage_collect: false do
                    task.stop!
                    sync.set
                end

                assert_kind_of Interrupt, task.failed_event.last.context.first
                assert_nil task.result
            end
        end
    end
end

