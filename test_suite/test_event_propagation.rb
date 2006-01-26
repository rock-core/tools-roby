require 'test_config'
require 'mockups/tasks'

class TC_EventPropagation < Test::Unit::TestCase
    def check_handlers_respond_to(task)
        assert( task.event_handlers.all? { |_, handlers| handlers.all? { |h| h.respond_to?(:call) } } )
    end

    def test_sequence
        check_handlers_respond_to(EmptyTask)   
        start_node = EmptyTask.new
        check_handlers_respond_to(start_node)   
        start_node.start!
        assert(start_node.finished?)

        start_node = EmptyTask.new
        if_node = ChoiceTask.new
        start_node.on(:stop, if_node, :start)
        start_node.start!
        assert(start_node.finished? && if_node.finished?)
    end
end
