require 'roby/test/self'
require 'roby/state/events'
require 'roby/state/pos'

class TC_StateEvents < Minitest::Test
    def test_pos_euler3d
	p = Pos::Euler3D.new(30)
	assert_equal(30, p.x)
	assert_equal(0, p.y)
	assert_equal(0, p.z)

	assert_equal(10, p.distance(30, 10))
	assert_equal(0, p.distance(p))
	assert_equal(0, Pos::Vector3D.new(30, 10, 50).distance2d(30, 10))

	assert_equal(Pos::Vector3D.new(-30), -p)
    end

    def test_pos_delta_event
	State.pos = Pos::Euler3D.new

	plan.add(d = State.on_delta(d: 10))
	assert_kind_of(PosDeltaEvent, d)
	d.poll
	assert_equal(State.pos, d.last_value)
	assert(!d.happened?)

	State.pos.x = 5
	d.poll
	assert(!d.happened?)

	State.pos.x = 10
	d.poll
	assert_equal(1, d.history.size)

	d.poll
	assert_equal(1, d.history.size)

	State.pos.x = 0
	d.poll
	assert_equal(2, d.history.size)
    end

    def test_yaw_delta_event
	State.pos = Pos::Euler3D.new

	plan.add(y = State.on_delta(yaw: 2))
	assert_kind_of(YawDeltaEvent, y)
	y.poll
	assert_equal(0, y.last_value)

	assert(!y.happened?)
	State.pos.yaw = 20
	y.poll
	assert(y.happened?)

	y.poll
	assert_equal(1, y.history.size)

	State.pos.yaw = 0
	y.poll
	assert_equal(2, y.history.size)
    end

    def test_time_delta_event
	FlexMock.use(Time) do |time_proxy|
	    current_time = Time.now + 5
	    time_proxy.should_receive(:now).and_return { current_time }

	    plan.add(t = State.on_delta(t: 1))
	    assert_kind_of(TimeDeltaEvent, t)

	    t.poll
	    assert(!t.happened?)
	    current_time += 0.5
	    t.poll
	    assert(!t.happened?)

	    current_time += 0.5
	    t.poll
	    assert_equal(1, t.history.size)

	    current_time += 0.5
	    t.poll
	    assert_equal(1, t.history.size)

	    current_time += 0.5
	    t.poll
	    assert_equal(2, t.history.size)
	end
    end

    def test_timepoint_event
	FlexMock.use(Time) do |time_proxy|
	    current_time = Time.now + 5
	    time_proxy.should_receive(:now).and_return { current_time }

	    plan.add(ev = State.at(t: current_time + 1))
	    ev.poll
	    assert(!ev.happened?)
	    current_time += 1
	    ev.poll
	    assert(ev.happened?)
	    current_time += 1
	    ev.poll
	    assert_equal(1, ev.history.size)
	end
    end

    def test_and_state_events
	State.pos = Pos::Euler3D.new
	plan.add_permanent(ev = State.on_delta(yaw: 2, d: 10))
	assert_kind_of(AndGenerator, ev)

	engine.process_events
	assert_equal(0, ev.history.size)

	State.pos.yaw = 1
	State.pos.x = 15
	engine.process_events
	assert_equal(0, ev.history.size)

	State.pos.yaw = 2
	engine.process_events
	assert_equal(1, ev.history.size)

	State.pos.yaw = 3
	State.pos.x = 25
	engine.process_events
	assert_equal(1, ev.history.size)

	State.pos.yaw = 4
	engine.process_events
	assert_equal(2, ev.history.size, ev.waiting.to_a)
    end

    def test_or_state_events
	State.pos = Pos::Euler3D.new
	plan.add_permanent(y = State.on_delta(yaw: 2))

	ev = y.or(d: 10)
	engine.process_events
	assert_equal(0, ev.history.size)

	State.pos.yaw = 1
	State.pos.x = 15
	engine.process_events
	assert_equal(1, ev.history.size)

	State.pos.yaw = 2
	engine.process_events
	assert_equal(1, ev.history.size)

	State.pos.yaw = 3
	engine.process_events
	assert_equal(2, ev.history.size)

	ev = ev.or(t: 3600)
	engine.process_events
	assert_equal(0, ev.history.size)

	time_event = plan.free_events.find { |t| t.kind_of?(TimeDeltaEvent) }
	time_event.instance_variable_set(:@last_value, Time.now - 3600)
	engine.process_events
	assert_equal(1, ev.history.size)
    end

    def test_condition_event
        FlexMock.use do |mock|
            event = State.trigger_when(:x) do |x|
                mock.condition(x)
                x > 10
            end
            plan.add_permanent(event)
            mock.should_receive(:condition).once.with(2)
            mock.should_receive(:condition).once.with(20)
            mock.should_receive(:condition).once.with(30)

            engine.process_events
            assert(!event.happened?)

            State.x = 2
            engine.process_events
            assert(!event.happened?)

            State.x = 20
            assert(event.armed?)
            engine.process_events
            assert(event.happened?)

            event.reset

            State.x = 30
            engine.process_events
        end
    end

    def test_reset_when
        FlexMock.use do |mock|
            event = State.trigger_when(:x) do |x|
                mock.condition(x)
                x > 10
            end
            reset_event = State.reset_when(event, :x) do |x|
                mock.reset_condition(x)
                x < 5
            end
            plan.add_permanent(event)
            mock.should_receive(:condition).at_least.once.with(2)
            mock.should_receive(:condition).once.with(20)
            mock.should_receive(:condition).once.with(30)

            mock.should_receive(:reset_condition).with(20)
            mock.should_receive(:reset_condition).at_least.once.with(30)
            mock.should_receive(:reset_condition).at_least.once.with(2)

            State.x = 2
            engine.process_events # does not emit (low value)
            State.x = 20
            engine.process_events # emits
            State.x = 30
            engine.process_events # does not emit (not reset yet)
            State.x = 2
            engine.process_events # resets
            State.x = 30
            engine.process_events # emits
            assert_equal 1, reset_event.history.size
            assert_equal 2, event.history.size
        end
    end

end


