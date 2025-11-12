# frozen_string_literal: true

require "roby/test/self"
require "roby/schedulers/global"

module Roby
    module Schedulers
        describe Global do
            before do
                @scheduler = Global.new(plan)
                @task_m = Tasks::Simple
            end

            describe "#create_scheduled_as_graph" do
                it "returns an empty graph if there are no tasks" do
                    graph = @scheduler.create_scheduled_as_graph([])
                    assert graph.empty?
                end

                it "adds singleton vertices to the graph" do
                    plan.add(task = @task_m.new)

                    graph = @scheduler.create_scheduled_as_graph([task])
                    assert graph.has_vertex?(task)
                end

                it "deletes non-pending tasks from the graph" do
                    plan.add(child = @task_m.new)
                    child.schedule_as(parent = @task_m.new)

                    graph = @scheduler.create_scheduled_as_graph([child])
                    refute graph.has_vertex?(parent)
                end

                it "normalizes scheduling constraints edges to map to tasks and have " \
                   "edges represent child.scheduled_as(parent)" do
                    plan.add(child = @task_m.new)
                    child.schedule_as(parent = @task_m.new)

                    graph = @scheduler.create_scheduled_as_graph([parent, child])
                    assert graph.has_edge?(child, parent)
                end

                it "normalizes dependency edges to have " \
                   "a.depends_on(b) be interpreted as b.schedule_as(a)" do
                    plan.add(parent = @task_m.new)
                    parent.depends_on(child = @task_m.new)

                    graph = @scheduler.create_scheduled_as_graph([parent, child])
                    assert graph.has_edge?(child, parent)
                end
            end

            describe "#create_scheduling_group_graph" do
                it "returns an empty graph if there are no tasks" do
                    scheduled_as = Relations::BidirectionalDirectedAdjacencyGraph.new
                    graph = @scheduler.create_scheduling_group_graph(scheduled_as)
                    assert graph.empty?
                end

                it "creates singleton sets if there are no loops" do
                    plan.add(t1 = @task_m.new)
                    plan.add(t2 = @task_m.new)
                    scheduled_as = Relations::BidirectionalDirectedAdjacencyGraph.new
                    scheduled_as.add_edge(t1, t2)
                    graph = @scheduler.create_scheduling_group_graph(scheduled_as)

                    assert_equal [Set[t1], Set[t2]], graph.each_vertex.map(&:tasks).to_a
                end

                it "creates edges between sets if they exist between tasks of each set" do
                    g0_t1, g0_t2, g1_t1, g1_t2 = 4.times.map { @task_m.new }

                    scheduled_as = Relations::BidirectionalDirectedAdjacencyGraph.new
                    scheduled_as.add_edge(g0_t1, g1_t1)
                    scheduled_as.add_edge(g0_t2, g1_t2)
                    scheduled_as.add_edge(g0_t1, g0_t2)
                    scheduled_as.add_edge(g0_t2, g0_t1)
                    scheduled_as.add_edge(g1_t1, g1_t2)
                    scheduled_as.add_edge(g1_t2, g1_t1)
                    graph = @scheduler.create_scheduling_group_graph(scheduled_as)

                    g0 = graph.each_vertex.find { |v| v.tasks == Set[g0_t1, g0_t2] }
                    assert g0
                    g1 = graph.each_vertex.find { |v| v.tasks == Set[g1_t1, g1_t2] }
                    assert g1
                    assert graph.has_edge?(g0, g1)
                end

                it "adds vertices for which there exist no edges" do
                    scheduled_as = Relations::BidirectionalDirectedAdjacencyGraph.new
                    plan.add(t1 = @task_m.new)
                    scheduled_as.add_vertex(t1)

                    graph = @scheduler.create_scheduling_group_graph(scheduled_as)
                    assert_equal [Set[t1]], graph.each_vertex.map(&:tasks)
                end

                it "converts to edges whose equality is done by identity" do
                    scheduled_as = Relations::BidirectionalDirectedAdjacencyGraph.new
                    plan.add(t1 = @task_m.new)
                    scheduled_as.add_vertex(t1)
                    graph = @scheduler.create_scheduling_group_graph(scheduled_as)

                    v0 = graph.each_vertex.first
                    assert graph.has_vertex?(v0)
                    refute graph.has_vertex?(v0.dup)
                end
            end

            describe "propagate_scheduling_state" do
                it "marks a group without any relationship as schedulable" do
                    plan.add(t = @task_m.new)
                    graph, (group,) = make_scheduling_groups([t])
                    @scheduler.propagate_scheduling_state([t], graph, Time.now)

                    assert_equal Global::STATE_SCHEDULABLE, group.state
                end

                it "sets its state to NON_SCHEDULABLE and adds itself to the " \
                   "held_non_schedulable set if a task in the group cannot be started" do
                    tasks, = make_task_groups(3)
                    tasks[0].executable = false
                    graph, (group,) = make_scheduling_groups(tasks)
                    @scheduler.propagate_scheduling_state(tasks, graph, Time.now)

                    assert_equal Global::STATE_NON_SCHEDULABLE, group.state
                    assert_equal Set[group], group.held_non_schedulable
                end

                it "propagates NON_SCHEDULABLE state to scheduled-as groups" do
                    tasks0, tasks1 = make_task_groups(2, 2)
                    tasks0[0].executable = false
                    graph, (g0, g1) = make_scheduling_groups(tasks0, tasks1)
                    graph.add_edge(g1, g0) # g1.schedule_as(g0)
                    @scheduler.propagate_scheduling_state(
                        tasks0 + tasks1, graph, Time.now
                    )

                    assert_equal Global::STATE_NON_SCHEDULABLE, g1.state
                    assert_equal Set[g0], g1.held_non_schedulable
                end

                it "propagates failed temporal constraints to scheduled-as groups" do
                    plan.add(prerequisite = @task_m.new(id: "prerequisite"))
                    tasks0, tasks1 = make_task_groups(2, 2)
                    tasks0[0].should_start_after prerequisite

                    graph, (g0, g1) = make_scheduling_groups(tasks0, tasks1)
                    graph.add_edge(g1, g0) # g1.schedule_as(g0)
                    @scheduler.propagate_scheduling_state(
                        tasks0 + tasks1, graph, Time.now
                    )

                    assert_equal Global::STATE_PENDING_TEMPORAL_CONSTRAINTS, g1.state
                    assert_equal Set[g0], g1.held_by_temporal
                end
            end

            describe "temporal constraints" do
                it "does nothing if a temporal constraint is not met, that is beyond " \
                   "the scheduler's reach" do
                    plan.add(prerequisite = @task_m.new(id: "pre"))
                    plan.add(task = @task_m.new(id: "task"))

                    task.should_start_after prerequisite
                    execute { prerequisite.start! }

                    assert_no_scheduled_tasks
                end

                it "does nothing if the task is scheduled as another, and that other " \
                   "has a temporal constraint is not met, that is beyond " \
                   "the scheduler's reach" do
                    plan.add(prerequisite = @task_m.new(id: "pre"))
                    plan.add(root = @task_m.new(id: "root"))
                    root.depends_on(@task_m.new(id: "child"))

                    root.should_start_after prerequisite
                    execute { prerequisite.start! }

                    assert_no_scheduled_tasks
                end

                it "does nothing if the task is scheduled as another, and that other " \
                   "has a temporal constraint not met, that is beyond " \
                   "the scheduler's reach even if there are internal temporal " \
                   "constraints as well" do
                    plan.add(prerequisite = @task_m.new(id: "pre"))
                    plan.add(root = @task_m.new(id: "root"))
                    root.should_start_after prerequisite
                    root.depends_on(child = @task_m.new(id: "child"))
                    child.depends_on(grandchild = @task_m.new(id: "grandchild"))
                    child.schedule_as(grandchild)
                    child.should_start_after(grandchild)

                    execute { prerequisite.start! }
                    assert_no_scheduled_tasks
                end

                it "does nothing if the task is scheduled as another, and that other " \
                   "has an external temporal constraint, even if there are " \
                   "cross-groups temporal constraints as well" do
                    plan.add(prerequisite = @task_m.new(id: "pre"))
                    plan.add(root = @task_m.new(id: "root"))
                    root.should_start_after prerequisite
                    root.depends_on(child = @task_m.new(id: "child"))
                    child.depends_on(grandchild = @task_m.new(id: "grandchild"))
                    child.should_start_after(grandchild)

                    execute { prerequisite.start! }
                    assert_no_scheduled_tasks
                end

                it "schedules a task that precedes another" do
                    plan.add(before = @task_m.new)
                    plan.add(after = @task_m.new)
                    after.should_start_after before.start_event

                    assert_scheduled_tasks([before])
                    execute { before.start! }
                    assert_scheduled_tasks([after])
                end

                it "lets a child start if its non-running parents are waiting for it" do
                    plan.add(root = @task_m.new)
                    root.depends_on(child = @task_m.new)
                    root.should_start_after child

                    assert_scheduled_tasks([child])
                end

                it "does not let a child start if its non-running parents " \
                   "are waiting for it, in case the parents themselves cannot be " \
                   "scheduled" do
                    plan.add(root = @task_m.new(id: "root"))
                    root.executable = false

                    root.depends_on(child = @task_m.new(id: "child"))
                    child.depends_on(grandchild = @task_m.new(id: "grandchild"))
                    child.should_start_after grandchild.start_event

                    assert_no_scheduled_tasks
                end

                it "handles complex schedule_as/temporal combinations" do
                    plan.add(root = @task_m.new)

                    root.depends_on(child = @task_m.new)
                    root.schedule_as(child)
                    child.depends_on(grandchild = @task_m.new)
                    child.should_start_after grandchild.start_event

                    assert_scheduled_tasks([grandchild])
                    execute { grandchild.start! }
                    assert_scheduled_tasks([root, child])
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
                        assert_no_scheduled_tasks
                    end

                    it "schedules if the child is executable and " \
                       "has no temporal constraints" do
                        assert_scheduled_tasks([@root, @child])
                    end

                    it "does not schedule if the child's temporal constraints " \
                       "are not met" do
                        plan.add(prerequisite = @task_m.new)
                        @child.should_start_after prerequisite.stop_event
                        execute { prerequisite.start! }

                        assert_no_scheduled_tasks
                    end

                    it "schedules if the child's temporal constraints " \
                       "are met" do
                        plan.add(prerequisite = @task_m.new)
                        @child.should_start_after prerequisite.start_event

                        assert_scheduled_tasks([prerequisite])
                        execute { prerequisite.start! }

                        assert_scheduled_tasks([@root, @child])
                    end

                    it "does not schedule if the child itself is synchronized with " \
                       "schedule_as and the constraints are not met" do
                        @child.depends_on(grandchild = @task_m.new)
                        @child.schedule_as grandchild
                        grandchild.executable = false

                        assert_no_scheduled_tasks
                    end

                    it "schedules if the child itself is synchronized with " \
                       "schedule_as and the constraints are met" do
                        @child.depends_on(grandchild = @task_m.new)
                        @child.schedule_as grandchild

                        assert_scheduled_tasks([@root, @child, grandchild])
                    end
                end

                describe "a planning task scheduled as its planned task" do
                    before do
                        plan.add(@planned_task = @task_m.new(id: "planned"))
                        @planned_task.planned_by(
                            @planning_task = @task_m.new(id: "planning")
                        )
                        @planning_task.schedule_as @planned_task
                        @planned_task.executable = false
                    end

                    it "schedules if the planned task is not executable" do
                        assert_scheduled_tasks([@planning_task])
                    end

                    it "schedules if the planned task is executable and " \
                       "has no temporal constraints" do
                        @planned_task.executable = true
                        assert_scheduled_tasks([@planning_task])
                    end

                    it "does not schedule if the child's temporal constraints " \
                       "are not met" do
                        plan.add(prerequisite = @task_m.new)
                        @planned_task.should_start_after prerequisite.stop_event

                        assert_no_scheduled_tasks
                    end

                    it "schedules if the child's temporal constraints " \
                       "are met" do
                        plan.add(prerequisite = @task_m.new(id: "pre"))
                        @planned_task.should_start_after prerequisite.start_event

                        assert_scheduled_tasks([prerequisite])
                        execute { prerequisite.start! }

                        assert_scheduled_tasks([@planning_task])
                    end

                    it "does not schedule if the child itself is synchronized with " \
                       "schedule_as and the constraints are not met" do
                        @planned_task.depends_on(grandchild = @task_m.new)
                        @planned_task.schedule_as grandchild
                        grandchild.executable = false

                        assert_no_scheduled_tasks
                    end

                    it "schedules if the child itself is synchronized with " \
                       "schedule_as and the constraints are met" do
                        @planned_task.depends_on(grandchild = @task_m.new)
                        @planned_task.schedule_as grandchild

                        assert_scheduled_tasks([@planning_task])
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

                    assert_scheduled_tasks([grandchild, planning_task])
                end

                it "handles having should_start_after on multiple children" do
                    root = @task_m.new(id: "root")
                    plan.add(root)

                    t1 = @task_m.new(id: "t1")
                    root.depends_on t1
                    root.should_start_after t1.start_event

                    t2 = @task_m.new(id: "t2")
                    root.depends_on t2
                    root.should_start_after t2.start_event

                    assert_scheduled_tasks([t1, t2])

                    execute { t1.start! }
                    assert_scheduled_tasks([t2])

                    execute { t2.start! }
                    assert_scheduled_tasks([root])
                end

                it "handles cycles in schedule_as mixed with should_start_after" do
                    root = @task_m.new(id: "root")
                    plan.add(root)

                    t1 = @task_m.new(id: "t1")
                    root.depends_on t1
                    root.should_start_after t1.start_event

                    t2 = @task_m.new(id: "t2")
                    root.depends_on t2
                    root.should_start_after t2.start_event
                    t2.schedule_as t1

                    assert_scheduled_tasks([t1, t2])

                    execute do
                        t1.start!
                        t2.start!
                    end
                    assert_scheduled_tasks([root])
                end
            end

            def assert_no_scheduled_tasks
                assert_equal Set.new, @scheduler.compute_tasks_to_schedule
            end

            def assert_scheduled_tasks(set)
                assert_equal set.to_set, @scheduler.compute_tasks_to_schedule
            end

            def make_task_groups(*counts)
                counts.each_with_index.map do |group_size, group_i|
                    group_size.times.map do |j|
                        t = @task_m.new(id: "g#{group_i}_#{j}")
                        plan.add(t)
                        t
                    end
                end
            end

            def make_scheduling_groups(*groups)
                groups = groups.map do |tasks|
                    Global::SchedulingGroup.new(
                        tasks: tasks.to_set, held_by_temporal: Set.new,
                        held_non_schedulable: Set.new
                    )
                end
                graph = Relations::BidirectionalDirectedAdjacencyGraph.new
                groups.each { |g| graph.add_vertex(g) }
                [graph, groups]
            end
        end
    end
end
