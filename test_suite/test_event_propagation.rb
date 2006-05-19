require 'flexmock'
require 'test_config'
require 'roby/event_loop'
require 'mockups/tasks'

class TC_EventPropagation < Test::Unit::TestCase
    def test_event_properties
	event = Roby::EventGenerator.new
	assert(! event.respond_to?(:call))
	assert(! event.controlable?)

	event = Roby::EventGenerator.new(true)
	assert(event.respond_to?(:call))
	assert(event.controlable?)

	FlexMock.use do |mock|
	    event = Roby::EventGenerator.new { mock.event }
	    assert(event.respond_to?(:call))
	    assert(event.controlable?)
	    mock.should_receive(:event).once
	    event.call(nil)
	end
    end

    def test_task_event_properties
        task = EmptyTask.new
	start_event = task.event(:start)

        assert_equal(start_event, task.event(:start))
        assert_equal([], start_event.handlers)
        assert_equal([], start_event.enum_for(:each_signal).to_a)
        start_model = start_node.event_model(:start)
        assert_equal(start_model, start_event.model)
        assert_equal([start_node.event_model(:stop)], start_node.enum_for(:each_signal, start_model).to_a)
        
	# Check that propagation is done properly in this simple task
        start_node.start!
        assert(start_node.finished?)
	event_history = start_node.history.map { |_, ev| ev.generator }
	assert_equal([start_node.event(:start), start_node.event(:stop)], event_history)

	# Check a more complex setup
        start_node = EmptyTask.new
        if_node = ChoiceTask.new
        start_node.on(:stop, if_node, :start)
        start_node.start!
        assert(start_node.finished? && if_node.finished?)

	# Check history
	event_history = if_node.history.map { |_, ev| ev.generator }
	assert_equal(3, event_history.size, "  " + event_history.join("\n"))
	assert_equal(if_node.event(:start), event_history.first)
	assert( if_node.event(:a) == event_history[1] || if_node.event(:b) == event_history[1] )
	assert_equal(if_node.event(:stop), event_history.last)

        multi_hop = MultiEventTask.new
        multi_hop.start!
        assert(multi_hop.finished?)
	event_history = multi_hop.history.map { |_, ev| ev.generator }
	expected_history = [:start, :inter, :stop].map { |name| multi_hop.event(name) }
	assert_equal(expected_history, event_history)
    end

    def test_ordering
	e1, e2, e3 = 4.enum_for(:times).map { Roby::EventGenerator.new(true) }
	e1.on(e2)
	e1.on { e2.remove_signal(e3) }
	e2.on(e3)

	e1.call(nil)
	assert( e2.happened? )
	assert( !e3.happened? )
    end


    def test_call_causal_warning
	model = Roby::EventGenerator.new { }
	model.call(nil)
	assert(! model.active? )

	source = Roby::EventGenerator.new { }
	def source.active?(seen); true end
	model = Roby::EventGenerator.new { source.add_causal_link model }
	assert(! model.active?)
	model.call(nil)
	assert(model.active?)
    end

    def test_emit_on
	t1, t2 = [nil,nil].map { EmptyTask.new }
	t1.event(:start).emit_on t2.event(:start)
        FlexMock.use do |mock|
	    t1.on(:start) { mock.t1 }
	    t2.on(:start) { mock.t2 }
	    mock.should_receive(:t2).once.ordered(:events)
	    mock.should_receive(:t1).once.ordered(:events)
	    t2.start!
	end
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

    def test_forwarder
	destinations = 5.enum_for(:times).map { Roby::EventGenerator.new(true) }
	source = Roby::ForwarderGenerator.new(*destinations)

	assert(destinations.all? { |ev| ev.parent_object?(source, Roby::EventStructure::Signals) })
	source.call(nil)
	assert(destinations.all? { |ev| ev.happened? })
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

    def aggregator_test(a, *tasks)
	if a.respond_to?(:start_event)
	    assert(a.start_event.controlable?)
	    assert(a.event(:start) == a.start_event)
	    assert(a.event(:stop)  == a.stop_event)
	end

	FlexMock.use do |mock|
	    a.on(:start) { mock.started }
	    a.on(:stop)  { mock.stopped }
	    mock.should_receive(:started).once.ordered(:start_stop)
	    mock.should_receive(:stopped).once.ordered(:start_stop)
	    a.event(:start).call(nil)
	end
	assert(tasks.all? { |t| t.finished? })
	assert(a.event(:stop).happened?)
	assert(a.finished?)
    end

    def test_task_parallel_aggregator
        t1, t2 = EmptyTask.new, EmptyTask.new
	aggregator_test((t1 | t2), t1, t2)
        t1, t2 = EmptyTask.new, EmptyTask.new
	aggregator_test( (t1 | t2).to_task, t1, t2 )
    end

    def test_task_sequence_aggregator
        t1, t2 = EmptyTask.new, EmptyTask.new
	aggregator_test( (t1 + t2), t1, t2 )
        t1, t2 = EmptyTask.new, EmptyTask.new
	s = t1 + t2
	aggregator_test( s.to_task, t1, t2 )
	assert(! t1.event(:stop).related_object?(s.event(:stop)))

        t1, t2, t3 = EmptyTask.new, EmptyTask.new, EmptyTask.new
        s = t2 + t3
	s.unshift t1
	aggregator_test(s, t1, t2, t3)
	
        t1, t2, t3 = EmptyTask.new, EmptyTask.new, EmptyTask.new
        s = t2 + t3
	s.unshift t1
	aggregator_test(s.to_task, t1, t2, t3)
    end

    def test_ensure
	setup = lambda do |mock|
	    t1, t2 = EmptyTask.new, EmptyTask.new
	    t1.event(:start).ensure_on t2.event(:start)
	    t1.event(:start).on { mock.started(t1) }
	    t2.event(:start).on { mock.started(t2) }
	    [t1, t2]
	end
	FlexMock.use do |mock|
	    t1, t2 = setup[mock]
	    mock.should_receive(:started).with(t1).once
	    mock.should_receive(:started).with(t2).never
	    t1.start!
	end
	FlexMock.use do |mock|
	    t1, t2 = setup[mock]
	    mock.should_receive(:started).with(t2).ordered(:t1_t2).once
	    mock.should_receive(:started).with(t1).ordered(:t1_t2).once
	    t2.start!
	end
	FlexMock.use do |mock|
	    t1, t2 = setup[mock]
	    mock.should_receive(:started).with(t1).ordered(:t1_t2).once
	    mock.should_receive(:started).with(t2).ordered(:t1_t2).once
	    t1.start!
	    t2.start!
	end
    end

end

