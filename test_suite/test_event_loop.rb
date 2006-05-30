require 'test_config'
require 'roby/event_loop'
require 'mockups/tasks'

class TC_EventLoop < Test::Unit::TestCase 
    include Roby

    def test_event_loop
        start_node = EmptyTask.new
        next_event = [ start_node, :start ]
        if_node    = ChoiceTask.new
        start_node.on(:stop) { next_event = [if_node, :start] }
	if_node.on(:stop) { raise Interrupt }
            
        Roby.event_processing << lambda do 
            next unless next_event
            task, event = *next_event
            next_event = nil
            task.event(event).call(nil)
        end
        assert_doesnt_timeout(1) { Roby.run }
        assert(start_node.finished?)
	assert(if_node.finished?)
    end
end


