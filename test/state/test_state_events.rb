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
        expect_execution { d.poll }.
            to { not_emit d }
        assert_equal(State.pos, d.last_value)

        State.pos.x = 5
        expect_execution { d.poll }.
            to { not_emit d }

        State.pos.x = 10
        expect_execution { d.poll }.
            to { emit d }

        expect_execution { d.poll }.
            to { not_emit d }

        State.pos.x = 0
        expect_execution { d.poll }.
            to { emit d }
    end

    def test_yaw_delta_event
        State.pos = Pos::Euler3D.new

        plan.add(y = State.on_delta(yaw: 2))
        assert_kind_of(YawDeltaEvent, y)
        y.poll
        assert_equal(0, y.last_value)

        assert(!y.emitted?)
        State.pos.yaw = 20
        expect_execution { y.poll }.
            to { emit y }

        expect_execution { y.poll }.
            to { not_emit y }

        State.pos.yaw = 0
        expect_execution { y.poll }.
            to { emit y }
    end

    def test_time_delta_event
        FlexMock.use(Time) do |time_proxy|
            current_time = Time.now + 5
            time_proxy.should_receive(:now).and_return { current_time }

            plan.add(ev = State.on_delta(t: 1))
            assert_kind_of(TimeDeltaEvent, ev)

            expect_execution { ev.poll }.
                to { not_emit ev }
            current_time += 0.5
            expect_execution { ev.poll }.
                to { not_emit ev }

            current_time += 0.5
            expect_execution { ev.poll }.
                to { emit ev }

            current_time += 0.5
            expect_execution { ev.poll }.
                to { not_emit ev }

            current_time += 0.5
            expect_execution { ev.poll }.
                to { emit ev }
        end
    end

    def test_timepoint_event
        FlexMock.use(Time) do |time_proxy|
            current_time = Time.now + 5
            time_proxy.should_receive(:now).and_return { current_time }

            plan.add(ev = State.at(t: current_time + 1))
            expect_execution { ev.poll }.
                to { not_emit ev }
            current_time += 1
            expect_execution { ev.poll }.
                to { emit ev }
            current_time += 1
            expect_execution { ev.poll }.
                to { not_emit ev }
        end
    end

    def test_and_state_events
        State.pos = Pos::Euler3D.new
        plan.add_permanent_event(ev = State.on_delta(yaw: 2, d: 10))
        assert_kind_of(AndGenerator, ev)

        execute_one_cycle
        assert_equal(0, ev.history.size)

        execute do
            State.pos.yaw = 1
            State.pos.x = 15
        end
        assert_equal(0, ev.history.size)

        execute do
            State.pos.yaw = 2
        end
        assert_equal(1, ev.history.size)

        execute do
            State.pos.yaw = 3
            State.pos.x = 25
        end
        assert_equal(1, ev.history.size)

        execute do
            State.pos.yaw = 4
        end
        assert_equal(2, ev.history.size, ev.waiting.to_a)
    end

    def test_or_state_events
        State.pos = Pos::Euler3D.new
        plan.add(y = State.on_delta(yaw: 2))

        ev = y.or(d: 10)
        expect_execution.to { not_emit ev }

        expect_execution do
            State.pos.yaw = 1
            State.pos.x = 15
        end.to { emit ev }

        expect_execution do
            State.pos.yaw = 2
        end.to { not_emit ev }

        expect_execution do
            State.pos.yaw = 3
        end.to { emit ev }

        ev = ev.or(t: 1)
        Timecop.freeze(base_time = Time.now)
        expect_execution.to { not_emit ev }

        Timecop.freeze(base_time + 1.1)
        expect_execution.to { emit ev }
    end

    def test_condition_event
        mock = flexmock

        event = State.trigger_when(:x) do |x|
            mock.condition(x)
            x > 10
        end
        plan.add(event)
        mock.should_receive(:condition).once.with(2)
        mock.should_receive(:condition).once.with(20)
        mock.should_receive(:condition).once.with(30)

        expect_execution.to { not_emit event }

        State.x = 2
        expect_execution.to { not_emit event }

        State.x = 20
        assert event.armed?
        expect_execution.to { emit event }

        event.reset

        State.x = 30
        expect_execution.to { emit event }
    end

    def test_reset_when
        mock = flexmock

        event = State.trigger_when(:x) do |x|
            mock.condition(x)
            x > 10
        end
        reset_event = State.reset_when(event, :x) do |x|
            mock.reset_condition(x)
            x < 5
        end
        plan.add(event)
        plan.add(reset_event)
        mock.should_receive(:condition).at_least.once.with(2)
        mock.should_receive(:condition).once.with(20)
        mock.should_receive(:condition).once.with(30)

        mock.should_receive(:reset_condition).with(20)
        mock.should_receive(:reset_condition).at_least.once.with(30)
        mock.should_receive(:reset_condition).at_least.once.with(2)

        State.x = 2
        expect_execution.to { not_emit event, reset_event }
        State.x = 20
        expect_execution.to { emit event; not_emit reset_event }
        State.x = 30
        expect_execution.to { not_emit event, reset_event }
        State.x = 2
        expect_execution.to { not_emit event; emit reset_event }
        State.x = 30
        expect_execution.to { emit event; not_emit reset_event }
    end

end


