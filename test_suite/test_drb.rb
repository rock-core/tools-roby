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
end

