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
	displayable = EventStructureDisplay::DisplayableTask[task]
	assert_nothing_raised { Marshal.dump(displayable) }
	assert_nothing_raised { YAML.dump(displayable) }

	displayable = EventStructureDisplay::DisplayableEvent[task.event(:start)]
	assert_nothing_raised { Marshal.dump(displayable) }
	assert_nothing_raised { YAML.dump(displayable) }

	displayable = EventStructureDisplay::DisplayableEvent[EventGenerator.new]
	assert_nothing_raised { Marshal.dump(displayable) }
	assert_nothing_raised { YAML.dump(displayable) }
    end
end

