require 'roby/test/self'
require 'roby'

class TC_KnownFailures < Test::Unit::TestCase
    include Roby::SelfTest

    def create_event_with_return; EventGenerator.new { |_| return } end
    def test_return_in_event_commands # WILL FAIL
        event = create_event_with_return
        plan.discover event

        assert_nothing_raised { event.call }
    end

    def test_return_in_task_commands
	model = Task.new_submodel do
            event :test_event do |context|
                return
            end
            event :stop, :command => true
	end

        plan.discover(task = model.new)
        task.start!

        assert_nothing_raised { task.test_event! }
        done_all = true

    ensure
        assert(done_all)
    end
end

