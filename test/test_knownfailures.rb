require 'roby/test/self'

class TC_KnownFailures < Minitest::Test
    def create_event_with_return; EventGenerator.new { |_| return } end
    def test_return_in_event_commands # WILL FAIL
        event = create_event_with_return
        plan.discover event

        event.call
    end

    def test_return_in_task_commands
	model = Task.new_submodel do
            event :test_event do |context|
                return
            end
            event :stop, command: true
	end

        plan.discover(task = model.new)
        task.start!

        task.test_event!
        done_all = true

    ensure
        assert(done_all)
    end
end

