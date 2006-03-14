require 'flexmock'
require 'test_config'
require 'roby/event_loop'
require 'mockups/tasks'

class TC_EventPropagation < Test::Unit::TestCase
    def test_propagation
        start_node = EmptyTask.new

        start_event = start_node.event(:start)
        assert_equal(start_event, start_node.event(:start))
        assert_equal([], start_event.handlers)
        assert_equal([], start_event.enum_for(:each_signal).to_a)
        start_model = start_node.event_model(:start)
        assert_equal(start_model, start_event.model)

        assert_equal([start_node.event_model(:stop)], start_model.enum_for(:each_signal).to_a)
        
        start_node.start!
        assert(start_node.finished?)

        start_node = EmptyTask.new
        start_node.start!
        assert(start_node.finished?)

        start_node = EmptyTask.new
        if_node = ChoiceTask.new
        start_node.on(:stop, if_node, :start)
        start_node.start!
        assert(start_node.finished? && if_node.finished?)

        multi_hop = MultiEventTask.new
        multi_hop.start!
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
            task.event(event).call(nil)
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
            empty.on(:stop) { multi.start! }
            mock.should_receive(:or).once
            mock.should_receive(:and).once
            mock.should_receive(:and_or).once
            mock.should_receive(:and_or_p).twice
            mock.should_receive(:or_and).once
            empty.start!
        end

        FlexMock.use do |mock|
            empty, multi = setup_aggregation(mock)
            mock.should_receive(:or).once
            mock.should_receive(:and).never
            mock.should_receive(:and_or).never
            mock.should_receive(:and_or_p).never
            mock.should_receive(:or_and).never
            empty.start!
        end

        FlexMock.use do |mock|
            empty, multi = setup_aggregation(mock)
            mock.should_receive(:or).once
            mock.should_receive(:and).never
            mock.should_receive(:and_or).once
            mock.should_receive(:and_or_p).once
            mock.should_receive(:or_and).once
            multi.start!
        end
    end

    def test_aggregator_causal
        a = EmptyTask.new
        b = EmptyTask.new
        c = EmptyTask.new

        and_event = a.event(:stop) & b.event(:stop)
        and_event.on(c.event(:start))
        assert( a.event(:stop).enum_for(:each_causal_link).find { |ev| ev == and_event } )
        assert( b.event(:stop).enum_for(:each_causal_link).find { |ev| ev == and_event } )
        assert( and_event.enum_for(:each_causal_link).find { |ev| ev == c.event(:start) } )

        ever_event = a.event(:start).ever
        ever_event.on(c.event(:start))
        assert( a.event(:start).enum_for(:each_causal_link).find { |ev| ev == ever_event } )
        assert( ever_event.enum_for(:each_causal_link).find { |ev| ev == c.event(:start) } )

        d = EmptyTask.new
        or_event = (b.event(:start) | c.event(:stop))
        or_event.on(d.event(:stop))
        assert( b.event(:start).enum_for(:each_causal_link).find { |ev| ev == or_event } )
        assert( or_event.enum_for(:each_causal_link).find { |ev| ev == d.event(:stop) } )
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

