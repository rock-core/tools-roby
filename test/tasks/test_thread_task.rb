require 'roby/test/self'
require 'roby/tasks/thread'

class TC_ThreadTask < Minitest::Test 
    # Starts +task+ and waits for the thread to end
    def wait_thread_end(task, exception: nil)
        if exception
            begin task.thread.join
            rescue exception
            end
        else
            task.thread.join
        end
    end

    def test_normal
        model = Roby::Tasks::Thread.new_submodel do
            implementation do
                1
            end
        end

        plan.add_mission_task(task = model.new)
        task.start!
	wait_thread_end(task)
        process_events

        assert task.success?
        assert_equal 1, task.result
    end

    def test_implementation_fails
        error = Class.new(ArgumentError)
        model = Roby::Tasks::Thread.new_submodel do
            implementation do
                raise error, "blaaaaaaaaah"
            end
        end

        plan.add_permanent_task(task = model.new)
        task.start!
        wait_thread_end(task, exception: error)
        assert_nonfatal_exception(PermanentTaskError, tasks: [task], original_exception: error, failure_point: task) do
            process_events
        end

        assert task.failed?
        assert_kind_of ArgumentError, task.event(:failed).last.context.first
        assert_equal nil, task.result
    end

    def test_interruptible
        model = Roby::Tasks::Thread.new_submodel do
            interruptible
            implementation do
                loop do
                    interruption_point
                    sleep 0.01
                end
            end
        end

        plan.add_permanent_task(task = model.new)
        task.start!
        task.stop!
        wait_thread_end(task, exception: Interrupt)
        assert_nonfatal_exception(PermanentTaskError, original_exception: Interrupt, tasks: [task]) do
            process_events
        end

        assert task.failed?
        assert_kind_of Interrupt, task.failed_event.last.context.first
        assert_equal nil, task.result
    end
end

