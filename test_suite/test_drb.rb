require 'test/unit'
require 'test_config'
require 'roby/event'
require 'roby/task'
require 'roby/display/event-structure'
require 'yaml'

class TC_Display < Test::Unit::TestCase
    include Roby
    def test_serializable_objects
	task = Class.new(Task) do 
	    event :start
	    event :stop
	end.new
	displayable = Display::Task[task]
	assert_nothing_raised { Marshal.dump(displayable) }
	assert_nothing_raised { YAML.dump(displayable) }

	displayable = Display::Event[task.event(:start)]
	assert_nothing_raised { Marshal.dump(displayable) }
	assert_nothing_raised { YAML.dump(displayable) }

	displayable = Display::Event[EventGenerator.new]
	assert_nothing_raised { Marshal.dump(displayable) }
	assert_nothing_raised { YAML.dump(displayable) }
    end

    def test_hash_values
	klass = Class.new(Task) do 
	    event :start
	    event :stop
	end
	t1, t2 = klass.new, klass.new
	assert_not_equal(Display::Task[t1].hash, Display::Task[t2].hash)
	assert(!Display::Task[t1].eql?(Display::Task[t2]))
	assert_not_equal(Display::Event[t1.event(:start)].hash, Display::Event[t1.event(:stop)].hash)
	assert(!Display::Event[t1.event(:start)].eql?(Display::Event[t1.event(:stop)]))
    end
end

