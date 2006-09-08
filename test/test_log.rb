require 'test/unit'
require 'test_config'
require 'roby/event'
require 'roby/task'
require 'roby/log/marshallable'
require 'yaml'

class TC_Log < Test::Unit::TestCase
    include Roby

    def assert_marshallable_wrapper(object)
	w = Marshallable::Wrapper[object]
	assert_nothing_raised { Marshal.dump(w) }
	assert_nothing_raised { YAML.dump(w) }
	w
    end

    def test_marshallable
	generator = EventGenerator.new(true)
	w_generator = assert_marshallable_wrapper(generator)
	generator.on do |event| 
	    w_event = assert_marshallable_wrapper(event)
	    assert_equal(w_generator, w_event.generator)
	end
	generator.call(nil)

	task = Class.new(Task) do 
	    event :start
	    event :stop
	end.new

	w_task = assert_marshallable_wrapper(task)
	w_task_start = assert_marshallable_wrapper(task.event(:start))
	assert_equal(w_task_start.task, w_task)
	task.on(:start) do |event|
	    w_event = assert_marshallable_wrapper(event)
	    assert_equal(w_event.generator, w_task_start)
	    assert_equal(w_event.task, w_task)
	end
    end
end

