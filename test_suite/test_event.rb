require 'flexmock'
require 'test_config'
require 'roby/event_loop'
require 'mockups/tasks'

class TC_Event < Test::Unit::TestCase
    def test_properties
	event = Roby::EventGenerator.new
	assert(! event.respond_to?(:call))
	assert(! event.controlable?)

	event = Roby::EventGenerator.new(true)
	assert(event.respond_to?(:call))
	assert(event.controlable?)

	# Check command & emission behavior for controlable events
	FlexMock.use do |mock|
	    event = Roby::EventGenerator.new { |context| mock.call_handler(context); event.emit(context) }
	    event.on { |event| mock.event_handler(event.context) }

	    assert(event.respond_to?(:call))
	    assert(event.controlable?)
	    mock.should_receive(:call_handler).once.with(42)
	    mock.should_receive(:event_handler).once.with(42)
	    event.call(42)
	end

	# Check emission behavior for non-controlable events
	FlexMock.use do |mock|
	    event = Roby::EventGenerator.new
	    event.on { |event| mock.event(event.context) }
	    mock.should_receive(:event).once.with(42)
	    event.emit(42)
	end
    end
    def test_emit_failed
	event = Roby::EventGenerator.new
	assert_raises(Roby::EventModelViolation) { event.emit_failed }
	assert_raises(Roby::EventModelViolation) { event.emit_failed("test") }

	klass = Class.new(Roby::EventModelViolation)
	assert_raises(klass) { event.emit_failed(klass) }
	assert_raises(klass) { event.emit_failed(klass, "test") }
	begin; event.emit_failed(klass, "test")
	rescue klass => e
	    assert( e.message =~ /: test$/ )
	end

	exception = klass.new(event)
	assert_raises(klass) { event.emit_failed(exception, "test") }
	begin; event.emit_failed(exception, "test")
	rescue klass => e
	    assert_equal(event, e.generator)
	    assert( e.message =~ /: test$/ )
	end
    end

    def test_signal_relation
	e1, e2 = Roby::EventGenerator.new(true), Roby::EventGenerator.new(true)

	e1.on e2
	assert( e1.child_object?( e2, Roby::EventStructure::Signals ))
	assert( e2.parent_object?( e1, Roby::EventStructure::Signals ))

	e1.call(nil)
	assert(e2.happened?)
    end
 
    def test_handlers
	e1, e2 = Roby::EventGenerator.new(true), Roby::EventGenerator.new(true)
	e1.on { e2.call(nil) }

	FlexMock.use do |mock|
	    e1.on { mock.e1 }
	    e2.on { mock.e2 }
	    mock.should_receive(:e1).once.ordered
	    mock.should_receive(:e2).once.ordered
	    e1.call(nil)
	end
    end

    def test_simple_signal_handler_ordering
	e1, e2, e3 = 4.enum_for(:times).map { Roby::EventGenerator.new(true) }
	e1.on(e2)
	e1.on { e2.remove_signal(e3) }
	e2.on(e3)

	e1.call(nil)
	assert( e2.happened? )
	assert( !e3.happened? )
    end

    def test_event_hooks
        FlexMock.use do |mock|
	    hooks = [:calling, :fired, :called]
            mod = Module.new do
		hooks.each do |name|
		    define_method(name) do |context|
			mock.send(name, self)
		    end
        	end
            end

            generator = Class.new(Roby::EventGenerator) do
		include mod
	    end.new(true)
            
	    hooks.each do |name|
		mock.should_receive(name).once.with(generator).ordered
	    end
            generator.call(nil)
        end
    end

    def test_postpone
	# Simple postpone behavior
	FlexMock.use do |mock|
	    wait_for = Roby::EventGenerator.new(true)
	    event = Roby::EventGenerator.new(true)
	    event.singleton_class.class_eval do
		define_method(:calling) do |context|
		    super if defined? super
		    postpone(wait_for, "bla") {}
		end
	    end

	    event.on { mock.event }
	    mock.should_receive(:event).never
	    event.call(nil)
	    assert(! event.happened? )
	    assert(! event.pending? )
	end

	# Test propagation when the block given to postpone 
	# signals some events
        FlexMock.use do |mock|
	    wait_for = Roby::EventGenerator.new(true)
	    event = Roby::EventGenerator.new(true)
	    event.singleton_class.class_eval do
		define_method(:calling) do |context|
		    super if defined? super
		    if !wait_for.happened?
			postpone(wait_for, "bla") do
			    wait_for.call(nil)
			end
		    end
		end
	    end

	    wait_for.on { mock.wait_for }
	    event.on { mock.event }
	    
	    mock.should_receive(:wait_for).once.ordered
	    mock.should_receive(:event).once.ordered
	    event.call(nil)
        end
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
	e1, e2 = [nil,nil].map { Roby::EventGenerator.new(true) }
	e1.emit_on e2
        FlexMock.use do |mock|
	    e1.on { mock.e1 }
	    e2.on { mock.e2 }
	    mock.should_receive(:e2).once.ordered
	    mock.should_receive(:e1).once.ordered
	    e2.call(nil)
	end
    end

    def setup_event_aggregator(aggregator)
	events = 10.enum_for(:times).map { Roby::EventGenerator.new(true) }
	events.each { |ev| aggregator << ev }
	events.each do |ev| 
	    ev.call(nil)
	    if ev != events[-1]
		yield
	    end
	end
    end

    def test_or_generator
	or_event = Roby::OrGenerator.new
	setup_event_aggregator(or_event) do
	    assert(or_event.happened?)
	end
    end

    def test_and_generator
	and_event = Roby::AndGenerator.new
	setup_event_aggregator(and_event) do
	    assert(!and_event.happened?)
	end
	assert(and_event.happened?)
    end

    def test_forwarder
	destinations = 5.enum_for(:times).map { Roby::EventGenerator.new(true) }
	source = Roby::ForwarderGenerator.new(*destinations)

	assert(destinations.all? { |ev| ev.parent_object?(source, Roby::EventStructure::Signals) })
	source.call(nil)
	assert(destinations.all? { |ev| ev.happened? })
    end

    def setup_aggregation(mock)
	e1, e2, m1, m2, m3 = 5.enum_for(:times).map { Roby::EventGenerator.new(true) }
	e1.on e2
	m1.on m2
	m2.on m3

        (e1 & e2 & m2).on { mock.and }
        (e2 | m1).on { mock.or }
        ((e2 & m1) | m2).on { mock.and_or }
        ((e2 & m1) | m2).on { mock.and_or_p }.
            permanent!

        ((e2 | m1) & m2).on { mock.or_and }
        [e1, e2, m1, m2, m3]
    end

    def test_aggregator
        FlexMock.use do |mock|
            e1, e2, m1, *_ = setup_aggregation(mock)
	    e2.on m1
            mock.should_receive(:or).once
            mock.should_receive(:and).once
            mock.should_receive(:and_or).once
            mock.should_receive(:and_or_p).once
            mock.should_receive(:or_and).once
            e1.call(nil)
        end

        FlexMock.use do |mock|
            e1, *_ = setup_aggregation(mock)
            mock.should_receive(:or).once
            mock.should_receive(:and).never
            mock.should_receive(:and_or).never
            mock.should_receive(:and_or_p).never
            mock.should_receive(:or_and).never
            e1.call(nil)
        end

        FlexMock.use do |mock|
            _, _, m1 = setup_aggregation(mock)
            mock.should_receive(:or).once
            mock.should_receive(:and).never
            mock.should_receive(:and_or).once
            mock.should_receive(:and_or_p).once
            mock.should_receive(:or_and).once
            m1.call(nil)
        end
    end

    def test_and
	a, b, c = 3.enum_for(:times).map { Roby::EventGenerator.new(true) }

        and_event = a & b
        and_event.on c
        assert( a.enum_for(:each_causal_link).find { |ev| ev == and_event } )
        assert( b.enum_for(:each_causal_link).find { |ev| ev == and_event } )
        assert( and_event.enum_for(:each_causal_link).find { |ev| ev == c } )
	a.call(nil)
	assert(! c.happened?)
	b.call(nil)
    end

    def test_ever
	a, b, c = 3.enum_for(:times).map { Roby::EventGenerator.new(true) }
        ever_event = a.ever
        ever_event.on c
        assert( a.enum_for(:each_causal_link).find { |ev| ev == ever_event } )
        assert( ever_event.enum_for(:each_causal_link).find { |ev| ev == c } )

	FlexMock.use do |mock|
	    c.on { mock.c }
	    
	    mock.should_receive(:c).twice
	    a.call(nil)
	    b.call(nil)
	    b.ever.on c
	    Roby.process_events
	end
    end

    def test_or
	a, b, c = 3.enum_for(:times).map { Roby::EventGenerator.new(true) }

        or_event = (a | b)
        or_event.on c
        assert( a.enum_for(:each_causal_link).find { |ev| ev == or_event } )
        assert( or_event.enum_for(:each_causal_link).find { |ev| ev == c } )
	a.call(nil)
	assert(c.happened?)
    end

    def test_ensure
	setup = lambda do |mock|
	    e1, e2 = Roby::EventGenerator.new(true), Roby::EventGenerator.new(true)
	    e1.ensure e2
	    e1.on { mock.e1 }
	    e2.on { mock.e2 }
	    [e1, e2]
	end
	FlexMock.use do |mock|
	    e1, e2 = setup[mock]
	    mock.should_receive(:e2).ordered.once
	    mock.should_receive(:e1).ordered.once
	    e1.call(nil)
	end
	FlexMock.use do |mock|
	    e1, e2 = setup[mock]
	    mock.should_receive(:e1).never
	    mock.should_receive(:e2).once
	    e2.call(nil)
	end
	FlexMock.use do |mock|
	    e1, e2 = setup[mock]
	    mock.should_receive(:e2).ordered.once
	    mock.should_receive(:e1).ordered.once
	    e2.call(nil)
	    e1.call(nil)
	end
    end

    def test_until
	e1, e2, e3, e4 = 4.enum_for(:times).map { Roby::EventGenerator.new(true) }
	e1.on(e2)
	e2.on(e3)
	e3.until(e2).on(e4)

	e1.call(nil)
	assert( e3.happened? )
	assert( !e4.happened? )
    end
end

