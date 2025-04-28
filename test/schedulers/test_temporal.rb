# frozen_string_literal: true

require "roby/test/self"
require "roby/schedulers/temporal"

module Roby
    module Schedulers
        describe Temporal do
            before do
                @scheduler = Roby::Schedulers::Temporal.new(true, true, plan)
                @task_m = Tasks::Simple
            end

            describe "temporal constraints" do
                before do
                    plan.add(@root = @task_m.new)
                    @root.depends_on(@child = @task_m.new)
                end

                it "lets a child start if its non-running parents are waiting for it" do
                    plan.add(root = @task_m.new)
                    root.depends_on(child = @task_m.new)
                    root.should_start_after child

                    refute @scheduler.can_schedule?(root, Time.now)
                    assert @scheduler.can_schedule?(child, Time.now)
                end

                it "does not let a child start if its non-running parents " \
                   "are waiting for it, in case the parents themselves cannot be " \
                   "scheduled" do
                    plan.add(root = @task_m.new)

                    root.depends_on(child = @task_m.new)
                    child.depends_on(grandchild = @task_m.new)
                    child.should_start_after grandchild

                    refute @scheduler.can_schedule?(child, Time.now)
                    refute @scheduler.can_schedule?(grandchild, Time.now)
                end

                it "handles complex schedule_as/temporal combinations" do
                    plan.add(root = @task_m.new)

                    root.depends_on(child = @task_m.new)
                    root.schedule_as(child)
                    child.depends_on(grandchild = @task_m.new)
                    child.should_start_after grandchild

                    refute @scheduler.can_schedule?(root, Time.now)
                    refute @scheduler.can_schedule?(child, Time.now)
                    assert @scheduler.can_schedule?(grandchild, Time.now)
                end
            end

            describe "#schedule_as" do
                describe "a parent scheduled as its child" do
                    before do
                        plan.add(@root = @task_m.new)
                        @root.depends_on(@child = @task_m.new)
                        @root.schedule_as @child
                    end

                    it "does not schedule if the child is not executable" do
                        @child.executable = false
                        refute @scheduler.can_schedule?(@root)
                    end

                    it "schedules if the child is executable and " \
                       "has no temporal constraints" do
                        assert @scheduler.can_schedule?(@root)
                    end

                    it "does not schedule if the child's temporal constraints " \
                       "are not met" do
                        plan.add(prerequisite = @task_m.new)
                        @child.should_start_after prerequisite.stop_event

                        refute @scheduler.can_schedule?(@root)
                    end

                    it "schedules if the child's temporal constraints " \
                       "are met" do
                        plan.add(prerequisite = @task_m.new)
                        @child.should_start_after prerequisite.start_event

                        execute do
                            prerequisite.start!
                        end

                        assert @scheduler.can_schedule?(@root)
                    end

                    it "does not schedule if the child itself is synchronized with " \
                       "schedule_as and the constraints are not met" do
                        @child.depends_on(grandchild = @task_m.new)
                        @child.schedule_as grandchild
                        grandchild.executable = false

                        refute @scheduler.can_schedule?(@root)
                    end

                    it "schedules if the child itself is synchronized with " \
                       "schedule_as and the constraints are met" do
                        @child.depends_on(grandchild = @task_m.new)
                        @child.schedule_as grandchild

                        assert @scheduler.can_schedule?(@root)
                    end
                end

                describe "a planning task scheduled as its planned task" do
                    before do
                        plan.add(@planned_task = @task_m.new)
                        @planned_task.planned_by(@planning_task = @task_m.new)
                        @planning_task.schedule_as @planned_task
                        @planned_task.executable = false
                    end

                    it "schedules if the planned task is not executable" do
                        assert @scheduler.can_schedule?(@planning_task)
                    end

                    it "schedules if the planned task is executable and " \
                       "has no temporal constraints" do
                        @planned_task.executable = true
                        assert @scheduler.can_schedule?(@planning_task)
                    end

                    it "does not schedule if the child's temporal constraints " \
                       "are not met" do
                        plan.add(prerequisite = @task_m.new)
                        @planned_task.should_start_after prerequisite.stop_event

                        refute @scheduler.can_schedule?(@planning_task)
                    end

                    it "schedules if the child's temporal constraints " \
                       "are met" do
                        plan.add(prerequisite = @task_m.new)
                        @planned_task.should_start_after prerequisite.start_event

                        execute do
                            prerequisite.start!
                        end

                        assert @scheduler.can_schedule?(@planning_task)
                    end

                    it "does not schedule if the child itself is synchronized with " \
                       "schedule_as and the constraints are not met" do
                        @planned_task.depends_on(grandchild = @task_m.new)
                        @planned_task.schedule_as grandchild
                        grandchild.executable = false

                        refute @scheduler.can_schedule?(@planning_task)
                    end

                    it "schedules if the child itself is synchronized with " \
                       "schedule_as and the constraints are met" do
                        @planned_task.depends_on(grandchild = @task_m.new)
                        @planned_task.schedule_as grandchild

                        assert @scheduler.can_schedule?(@planning_task)
                    end
                end

                it "start planning a granchild of tasks that are scheduled " \
                   "as their children" do
                    plan.add(root = @task_m.new)
                    root.depends_on(child = @task_m.new)
                    root.schedule_as child
                    child.depends_on(grandchild = @task_m.new)
                    child.schedule_as grandchild
                    grandchild.executable = false
                    grandchild.planned_by(planning_task = @task_m.new)
                    planning_task.schedule_as grandchild

                    refute @scheduler.can_schedule?(root)
                    refute @scheduler.can_schedule?(child)
                    assert @scheduler.can_schedule?(grandchild)
                    assert @scheduler.can_schedule?(planning_task)
                end
            end
        end
    end
end

class TC_Schedulers_Temporal < Minitest::Test
    attr_reader :scheduler

    def scheduler_initial_events
        loop do
            break if execute { scheduler.initial_events.empty? }
        end
    end

    def setup
        super
        @scheduler = Roby::Schedulers::Temporal.new(true, true, plan)
    end

    def test_scheduling_time
        t1, t2, t3 = prepare_plan add: 3, model: Tasks::Simple
        e1 = t1.start_event
        e2 = t2.start_event
        e3 = t3.start_event
        t1.executable = false

        e2.should_emit_after(e1, min_t: 5, max_t: 10)
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
        mock = flexmock("event ordering for #{events.map(&:to_s).join(', ')}")
        events.each do |ev|
            mock.should_receive(:emitted).with(ev).ordered.once
            ev.on { |event| mock.emitted(event.generator) }
        end
    end

    def test_scheduling_constraint
        scheduler = Roby::Schedulers::Temporal.new(true, true, plan)

        t2, t3 = prepare_plan add: 2, model: Tasks::Simple
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
        execute { t3.success! }
        assert(!t3.running?)
        2.times do
            scheduler_initial_events
            assert(t2.running?)
        end
    end

    def test_temporal_constraints
        scheduler = Roby::Schedulers::Temporal.new(true, true, plan)
        t1, t1_child, t2, t2_child = prepare_plan add: 4, model: Tasks::Simple
        t1.depends_on(t1_child)
        t2.depends_on(t2_child)
        t2_child.should_start_after(t1_child)

        execute { t1.start! }
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

        execute do
            t1.stop!
            t1_child.stop!
        end
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
        t0, t1, t2, t3 = prepare_plan add: 4, model: Tasks::Simple
        t0.depends_on t1
        t1.depends_on t2
        t2.planned_by t3
        t2.should_start_after(t3)
        t3.schedule_as(t2)

        execute { t0.start! }

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

        execute { t3.success! }
        assert scheduler.can_schedule?(t2, Time.now)
        scheduler_initial_events
        assert(t2.running?)
    end
end
