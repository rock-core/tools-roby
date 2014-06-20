require 'roby/test/self'
require 'roby/schedulers/temporal'

class TC_Schedulers_Temporal < Minitest::Test
    attr_reader :scheduler

    def scheduler_initial_events
        while !scheduler.initial_events.empty?
        end
    end

    def setup
        super
        @scheduler = Roby::Schedulers::Temporal.new(true, true, plan)
    end

    def test_scheduling_time
        t1, t2, t3 = prepare_plan :add => 3, :model => Tasks::Simple
        e1 = t1.start_event
        e2 = t2.start_event
        e3 = t3.start_event
        t1.executable = false

        e2.should_emit_after(e1, :min_t => 5, :max_t => 10)
        t2.depends_on t3

        FlexMock.use(Time) do |time|
            current_time = Time.now
            time.should_receive(:now).and_return { current_time }

            scheduler_initial_events
            assert !t1.running?
            assert !t2.running?
            assert !t3.running?

            t1.executable = true
            scheduler_initial_events
            assert t1.running?
            assert !t2.running?
            assert !t3.running?

            current_time += 6
            verify_event_ordering(t2.start_event, t3.start_event)
            scheduler_initial_events
            assert t1.running?
            assert t2.running?
            assert t3.running?
        end
    end

    def verify_event_ordering(*events)
        mock = flexmock("event ordering for #{events.map(&:to_s).join(", ")}")
        events.each do |ev|
            mock.should_receive(:emitted).with(ev).ordered.once
            ev.on { |event| mock.emitted(event.generator) }
        end
    end

    def test_scheduling_constraint
        scheduler = Roby::Schedulers::Temporal.new(true, true, plan)

        t2, t3 = prepare_plan :add => 2, :model => Tasks::Simple
        t2.planned_by t3
        t2.should_start_after(t3)
        t3.schedule_as(t2)
        t2.executable = false

        assert !scheduler.can_schedule?(t2)
        assert scheduler.can_schedule?(t2, Time.now, [t3])
        assert scheduler.can_schedule?(t3)

        2.times do
            scheduler_initial_events
            assert(!t2.running?)
            assert(t3.running?)
        end

        t2.executable = true
        t3.success!
        assert(!t3.running?)
        2.times do
            scheduler_initial_events
            assert(t2.running?)
        end
    end

    def test_temporal_constraints
        scheduler = Roby::Schedulers::Temporal.new(true, true, plan)
        t1, t1_child, t2, t2_child = prepare_plan :add => 4, :model => Tasks::Simple
        t1.depends_on(t1_child)
        t2.depends_on(t2_child)
        t2_child.should_start_after(t1_child)

        t1.start!
        assert scheduler.can_schedule?(t1, Time.now)
        assert scheduler.can_schedule?(t1_child, Time.now)
        assert scheduler.can_schedule?(t2, Time.now)
        assert !scheduler.can_schedule?(t2_child, Time.now)

        2.times do
            scheduler_initial_events
            assert(t1.running?)
            assert(t1_child.running?)
            assert(t2.running?)
            assert(!t2_child.running?)
        end

        t1.stop!
        t1_child.stop!
        assert scheduler.can_schedule?(t2_child, Time.now)
        2.times do
            scheduler_initial_events
            assert(!t1.running?)
            assert(!t1_child.running?)
            assert(t2.running?)
            assert(t2_child.running?)
        end
    end

    def test_mixing_scheduling_and_basic_constraints
        scheduler = Roby::Schedulers::Temporal.new(true, true, plan)
        t0, t1, t2, t3 = prepare_plan :add => 4, :model => Tasks::Simple
        t0.depends_on t1
        t1.depends_on t2
        t2.planned_by t3
        t2.should_start_after(t3)
        t3.schedule_as(t2)

        t0.start!

        t1.executable = false
        assert scheduler.can_schedule?(t1, Time.now)
        assert !scheduler.can_schedule?(t2, Time.now)
        assert !scheduler.can_schedule?(t3, Time.now)
        scheduler_initial_events
        assert(!t1.running?)
        assert(!t2.running?)
        assert(!t3.running?)

        t1.executable = true
        verify_event_ordering(t1.start_event, t3.start_event)
        scheduler_initial_events
        assert(t1.running?)
        assert(!t2.running?)
        assert(t3.running?)

        t3.success!
        assert scheduler.can_schedule?(t2, Time.now)
        scheduler_initial_events
        assert(t2.running?)
    end

    def test_parent_waiting_for_child
        scheduler = Roby::Schedulers::Temporal.new(true, true, plan)
        t0, t1 = prepare_plan :add => 2, :model => Tasks::Simple
        t0.depends_on t1
        t0.should_start_after(t1)

        assert !scheduler.can_schedule?(t0, Time.now)
        assert scheduler.can_schedule?(t1, Time.now)
    end
end



