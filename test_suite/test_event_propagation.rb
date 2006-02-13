require 'flexmock'
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

        multi_hop = MultiEventTask.new
        multi_hop.emit :start
        assert(multi_hop.finished?)
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

    def setup_aggregation(mock)
        empty = EmptyTask.new
        multi = MultiEventTask.new

        (empty.event(:start) & empty.event(:stop) & multi.event(:inter)).
            on { mock.and }

        (empty.event(:stop) | multi.event(:start)).
            on { mock.or }

        ((empty.event(:stop) & multi.event(:start)) | multi.event(:inter)).
            on { mock.and_or }

        ((empty.event(:stop) & multi.event(:start)) | multi.event(:inter)).
            on { mock.and_or_p }.
            permanent!

        ((empty.event(:stop) | multi.event(:start)) & multi.event(:inter)).
            on { mock.or_and }


        [empty, multi]
    end

    def test_aggregator
        FlexMock.use do |mock|
            empty, multi = setup_aggregation(mock)
            empty.on(:stop) { multi.emit(:start) }
            mock.should_receive(:or).once
            mock.should_receive(:and).once
            mock.should_receive(:and_or).once
            mock.should_receive(:and_or_p).twice
            mock.should_receive(:or_and).once
            empty.emit(:start)
        end

        FlexMock.use do |mock|
            empty, multi = setup_aggregation(mock)
            mock.should_receive(:or).once
            mock.should_receive(:and).never
            mock.should_receive(:and_or).never
            mock.should_receive(:and_or_p).never
            mock.should_receive(:or_and).never
            empty.emit(:start)
        end

        FlexMock.use do |mock|
            empty, multi = setup_aggregation(mock)
            mock.should_receive(:or).once
            mock.should_receive(:and).never
            mock.should_receive(:and_or).once
            mock.should_receive(:and_or_p).once
            mock.should_receive(:or_and).once
            multi.emit(:start)
        end
    end

    def test_task_aggregator
        t1, t2 = EmptyTask.new, EmptyTask.new
        p = t1 | t2
        p.start!(nil)
        assert(t1.finished? && t2.finished?)
        assert(p.finished?)

        t1, t2 = EmptyTask.new, EmptyTask.new
        s = t1 + t2
        s.start!(nil)
        assert(t1.finished? && t2.finished?)
        assert(s.finished?)
    end
end

