$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/self'
require 'roby/tasks/simple'
require 'roby/schedulers/basic'
require 'flexmock/test_unit'

class TC_Schedulers_Basic < Test::Unit::TestCase
    include Roby::SelfTest

    attr_reader :scheduler

    def verify_event_ordering(*events)
        mock = flexmock("event ordering for #{events.map(&:to_s).join(", ")}")
        events.each do |ev|
            mock.should_receive(:emitted).with(ev).ordered.once
            ev.on { |event| mock.emitted(event.generator) }
        end
    end

    def scheduler_initial_events
        while !scheduler.initial_events.empty?
        end
    end

    def test_non_executable
        @scheduler = Roby::Schedulers::Basic.new(false, plan)
        t1 = prepare_plan :add => 1, :model => Tasks::Simple

        t1.executable = false
        scheduler_initial_events
        assert !t1.running?

        t1.executable = true
        scheduler_initial_events
        assert t1.running?
    end

    def test_event_ordering
        @scheduler = Roby::Schedulers::Basic.new(false, plan)
        t1, t2 = prepare_plan :add => 2, :model => Tasks::Simple
        t1.stop_event.signals t2.start_event

        scheduler_initial_events
        assert t1.running?
        assert !t2.running?
        scheduler_initial_events
        assert t1.running?
        assert !t2.running?
    end

    def test_without_children
        @scheduler = Roby::Schedulers::Basic.new(false, plan)
        t1, t2 = prepare_plan :add => 2, :model => Tasks::Simple
        t1.depends_on t2

        scheduler_initial_events
        assert t1.running?
        assert !t2.running?
        scheduler_initial_events
        assert t1.running?
        assert !t2.running?
    end

    def test_with_children
        @scheduler = Roby::Schedulers::Basic.new(true, plan)
        t1, t2 = prepare_plan :add => 2, :model => Tasks::Simple
        t1.depends_on t2

        verify_event_ordering(t1.start_event, t2.start_event)
        scheduler_initial_events
        assert t1.running?
        assert t2.running?
        scheduler_initial_events
        assert t1.running?
        assert t2.running?
    end

    def test_planned_by
        @scheduler = Roby::Schedulers::Basic.new(true, plan)
        t1, t2, t3 = prepare_plan :add => 3, :model => Tasks::Simple
        t1.depends_on t2
        t2.executable = false
        t2.planned_by t3

        scheduler_initial_events
        assert t1.running?
        assert !t2.running?
        assert t3.running?
    end
end



