require 'test_config'
require 'roby/event_loop'
require 'mockups/tasks'

class TC_EventPropagation < Test::Unit::TestCase
    def check_handlers_respond_to(task)
        assert( task.event_handlers.all? { |_, handlers| handlers.all? { |h| h.respond_to?(:call) } } )
    end

    def test_propagation
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

    def test_event_loop
        watchdog = Thread.new do 
            sleep(2)
            assert(false)
        end

        start_node = EmptyTask.new
        next_event = [ start_node, :start ]
        if_node    = ChoiceTask.new
        start_node.on(:stop) { next_event = [if_node, :start] }
        if_node.on(:stop) { raise Interrupt }
            
        Roby.event_processing << lambda do 
            next unless next_event
            task, event = *next_event
            next_event = nil
            task.send_command(event)
        end
        assert_doesnt_timeout(1) { Roby.run }
        assert(start_node.finished? && if_node.finished?)
    end
end
