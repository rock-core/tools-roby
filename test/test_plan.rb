require 'roby/test/self'

module TC_PlanStatic
    include Roby
    def assert_task_state(task, state)
        if state == :removed
            assert(!plan.has_task?(task), "task was meant to be removed, but Plan#has_task? still returns true")
            assert(!plan.permanent_task?(task), "task was meant to be removed, but Plan#permanent_task? still returns true")
            assert(!plan.mission_task?(task), "task was meant to be removed, but Plan#mission_task? returns true")
            assert(!task.mission?, "task was meant to be removed, but Task#mission? returns true")
            assert_equal(nil, task.plan, "task was meant to be removed, but PlanObject#plan returns a non-nil value")
        else
            assert_equal(plan, task.plan, "task was meant to be included in a plan but PlanObject#plan returns nil")
            assert(plan.has_task?(task), "task was meant to be included in a plan but Plan#has_task? returned false")
            if state == :permanent
                assert(plan.permanent_task?(task), "task was meant to be permanent but Plan#permanen_taskt? returned false")
            else
                assert(!plan.permanent_task?(task), "task was not meant to be permanent but Plan#permanen_taskt? returned true")
            end

            if state == :mission
                assert(plan.mission_task?(task), "task was meant to be a mission, but Plan#mission_task? returned false")
                assert(task.mission?, "task was meant to be a mission, but Task#mission_task? returned false")
            elsif state == :permanent
                assert(!plan.mission_task?(task), "task was meant to be permanent but Plan#mission_task? returned true")
                assert(!task.mission?, "task was meant to be permanent but Task#mission? returned true")
            elsif state == :normal
                assert(!plan.mission_task?(task), "task was meant to be permanent but Plan#mission_task? returned true")
                assert(!task.mission?, "task was meant to be permanent but Task#mission? returned true")
            end
        end
    end
    def assert_event_state(event, state)
        if state == :removed
            assert(!plan.has_free_event?(event), "event was meant to be removed, but Plan#has_free_event? still returns true")
            assert(!plan.permanent_event?(event), "event was meant to be removed, but Plan#permanent_event? still returns true")
            assert_equal(nil, event.plan, "event was meant to be removed, but PlanObject#plan returns a non-nil value")
        else
            assert_equal(plan, event.plan, "event was meant to be included in a plan but PlanObject#plan returns nil")
            assert(plan.has_free_event?(event), "event was meant to be included in a plan but Plan#has_free_event? returned false")
            if state == :permanent
                assert(plan.permanent_event?(event), "event was meant to be permanent but Plan#permanent_event? returned false")
            else
                assert(!plan.permanent_event?(event), "event was not meant to be permanent but Plan#permanent_event? returned true")
            end
        end
    end

    def test_add_task
	plan.add(t = Task.new)
        assert_same t.relation_graphs, plan.task_relation_graphs
        assert_task_state(t, :normal)
        assert_equal plan, t.plan

        other_plan = Plan.new
        assert_raises(ModelViolation) { other_plan.add(t) }
        assert !other_plan.has_task?(t)
        assert_same t.relation_graphs, plan.task_relation_graphs
    end

    def test_add_plan
	t1, t2, t3 = (1..3).map { Roby::Task.new }
        ev = EventGenerator.new
	t1.depends_on t2
	t2.depends_on t3
        t1.stop_event.signals t3.start_event
        t3.stop_event.forward_to ev
        plan.add(t1)

        assert_equal [t1, t2, t3].to_set, plan.tasks
        expected = [t1, t2, t3].flat_map { |t| t.each_event.to_a }.to_set
        assert_equal expected, plan.task_events
        assert_equal [ev].to_set, plan.free_events
        assert t1.child_object?(t2, TaskStructure::Dependency)
        assert t2.child_object?(t3, TaskStructure::Dependency)
        assert t1.stop_event.child_object?(t3.start_event, EventStructure::Signal)
        assert t3.stop_event.child_object?(ev, EventStructure::Forwarding)
    end

    def test_removing_a_task_deregisters_it_from_the_plan
        t = prepare_plan add: 1
        assert_task_state(t, :normal)
        plan.remove_task(t)
        assert_task_state(t, :removed)
    end

    def test_add_mission_task
	plan.add_mission_task(t = Task.new)
        assert_task_state(t, :mission)
    end
    
    def test_unmark_mission_task
	plan.add_mission_task(t = Task.new)
	plan.unmark_mission_task(t)
        assert_task_state(t, :normal)
    end
    def test_removed_mission
	plan.add_mission_task(t = Task.new)
	plan.remove_task(t)
        assert_task_state(t, :removed)
    end

    def test_add_permanent_task
	plan.add_permanent_task(t = Task.new)
        assert_task_state(t, :permanent)
    end
    def test_unmark_permanent_task
	plan.add_permanent_task(t = Task.new)
	plan.unmark_permanent_task(t)
        assert_task_state(t, :normal)
    end
    def test_remove_permanent_task
	plan.add_permanent_task(t = Task.new)
	plan.remove_task(t)
        assert_task_state(t, :removed)
    end

    def test_add_event
	plan.add(ev = EventGenerator.new)
        assert_event_state(ev, :normal)
    end
    def test_remove_free_event
	plan.add(ev = EventGenerator.new)
	plan.remove_free_event(ev)
        assert_event_state(ev, :removed)
    end
    def test_add_permanent_event
	plan.add_permanent_event(ev = EventGenerator.new)
        assert_event_state(ev, :permanent)
    end
    def test_unmark_permanent_event
	plan.add_permanent_event(ev = EventGenerator.new)
	plan.unmark_permanent_event(ev)
        assert_event_state(ev, :normal)
    end

    def test_replace_task
	(p, c1), (c11, c12, c2, c3) = prepare_plan missions: 2, tasks: 4, model: Roby::Tasks::Simple
	p.depends_on c1, model: [Roby::Tasks::Simple, {}]
	c1.depends_on c11
	c1.depends_on c12
	p.depends_on c2
        c1.stop_event.signals c2.start_event
        c1.start_event.forward_to c1.stop_event
        c11.success_event.forward_to c1.success_event

        plan.replace_task(c1, c3)

	# Check that the external task and event structures have been
	# transferred. 
	assert( !p.child_object?(c1, TaskStructure::Dependency) )
	assert( p.child_object?(c3, TaskStructure::Dependency) )
	assert( c3.child_object?(c11, TaskStructure::Dependency) )
	assert( !c1.child_object?(c11, TaskStructure::Dependency) )

	assert( !c1.event(:stop).child_object?(c2.event(:start), EventStructure::Signal) )
	assert( c3.event(:stop).child_object?(c2.event(:start), EventStructure::Signal) )
	assert( c3.event(:success).parent_object?(c11.event(:success), EventStructure::Forwarding) )
	assert( !c1.event(:success).parent_object?(c11.event(:success), EventStructure::Forwarding) )
	# Also check that the internal event structure has *not* been transferred
	assert( !c3.event(:start).child_object?(c3.event(:stop), EventStructure::Forwarding) )
	assert( c1.event(:start).child_object?(c1.event(:stop), EventStructure::Forwarding) )

	# Check that +c1+ is no more marked as mission, and that c3 is marked. c1 should
	# still be in the plan
	assert(! plan.mission_task?(c1) )
	assert( plan.mission_task?(c3) )
	assert( plan.has_task?(c1) )

	# Check that #replace_task keeps the permanent flag too
	(root, p), t = prepare_plan permanent: 2, tasks: 1, model: Roby::Tasks::Simple
        root.depends_on p, model: Roby::Tasks::Simple

	plan.add_permanent_task(p)
	plan.replace_task(p, t)
	assert(!plan.permanent_task?(p))
	assert(plan.permanent_task?(t))
    end

    def test_replace_task_raises_ArgumentError_if_one_argument_is_finalized
        plan.add(task = Roby::Task.new)
        plan.add(finalized = Roby::Task.new)
        plan.remove_object(finalized)
        assert_raises(ArgumentError) { plan.replace_task(task, finalized) }
        assert_raises(ArgumentError) { plan.replace_task(finalized, task) }
    end

    def test_replace_raises_ArgumentError_if_one_argument_is_nil
        plan.add(task = Roby::Task.new)
        plan.add(finalized = Roby::Task.new)
        plan.remove_object(finalized)
        assert_raises(ArgumentError) { plan.replace(task, finalized) }
        assert_raises(ArgumentError) { plan.replace(finalized, task) }
    end

    def test_replace
	(p, c1), (c11, c12, c2, c3) = prepare_plan missions: 2, tasks: 4, model: Roby::Tasks::Simple
	p.depends_on c1, model: Roby::Tasks::Simple
	c1.depends_on c11
	c1.depends_on c12
	p.depends_on c2
        c1.stop_event.signals c2.start_event
        c1.start_event.forward_to c1.stop_event
        c11.success_event.forward_to c1.success_event

	# Replace c1 by c3 and check that the hooks are properly called
        plan.replace(c1, c3)

	# Check that the external task and event structures have been
	# transferred. 
	assert( !p.child_object?(c1, TaskStructure::Dependency) )
	assert( p.child_object?(c3, TaskStructure::Dependency) )
	assert( c1.child_object?(c11, TaskStructure::Dependency) )
	assert( !c3.child_object?(c11, TaskStructure::Dependency) )

	assert( !c1.stop_event.child_object?(c2.start_event, EventStructure::Signal) )
	assert( c3.stop_event.child_object?(c2.start_event, EventStructure::Signal) )
	assert( c1.success_event.parent_object?(c11.success_event, EventStructure::Forwarding) )
	assert( !c3.success_event.parent_object?(c11.success_event, EventStructure::Forwarding) )
	# Also check that the internal event structure has *not* been transferred
	assert( !c3.start_event.child_object?(c3.stop_event, EventStructure::Forwarding) )
	assert( c1.start_event.child_object?(c1.stop_event, EventStructure::Forwarding) )

	# Check that +c1+ is no more marked as mission, and that c3 is marked. c1 should
	# still be in the plan
	assert(! plan.mission_task?(c1) )
	assert( plan.mission_task?(c3) )
	assert( plan.has_task?(c1) )
    end

    def test_replace_task_and_strong_relations
        t0, t1, t2, t3 = prepare_plan add: 4, model: Roby::Tasks::Simple

        t0.depends_on t1, model: Roby::Tasks::Simple
        t1.depends_on t2
        t1.stop_event.handle_with t2
        # The error handling relation is strong, so the t1 => t3 relation should
        # not be replaced at all
        plan.replace_task(t1, t3)

        assert !t1.depends_on?(t2)
        assert  t3.depends_on?(t2)
        assert  t1.child_object?(t2, TaskStructure::ErrorHandling)
        assert !t3.child_object?(t2, TaskStructure::ErrorHandling)
    end

    def test_replace_task_and_copy_relations_on_replace
        agent_t = Roby::Task.new_submodel do
            event :ready, controlable: true
        end

        t0, t1, t3 = prepare_plan add: 3, model: Roby::Tasks::Simple
        plan.add(t2 = agent_t.new)

        t0.depends_on t1, model: Roby::Tasks::Simple
        t1.executed_by t2

        # The error handling relation is marked as copy_on_replace, so the t1 =>
        # t2 relation should not be removed, but only copied
        plan.replace_task(t1, t3)

        assert t1.child_object?(t2, TaskStructure::ExecutionAgent)
        assert t3.child_object?(t2, TaskStructure::ExecutionAgent)
    end

    def test_replace_can_replace_a_task_with_unset_delayed_arguments
        task_m = Roby::Task.new_submodel do
            argument :arg
        end
        delayed_arg = flexmock(evaluate_delayed_argument: nil)
        plan.add(original = task_m.new(arg: delayed_arg))
        plan.add(replacing = task_m.new(arg: 10))
        plan.replace(original, replacing)
    end

    def test_free_events
	t1, t2, t3 = (1..3).map { Roby::Task.new }
	plan.add_mission_task(t1)
	t1.depends_on t2
	assert_equal(plan, t2.plan)
	assert_equal(plan, t1.event(:start).plan)

	or_generator  = (t1.event(:stop) | t2.event(:stop))
	assert_equal(plan, or_generator.plan)
	assert(plan.has_free_event?(or_generator))
	or_generator.signals t3.event(:start)
	assert_equal(plan, t3.plan)

	and_generator = (t1.event(:stop) & t2.event(:stop))
	assert_equal(plan, and_generator.plan)
	assert(plan.has_free_event?(and_generator))
    end

    def test_plan_synchronization
	t1, t2 = prepare_plan tasks: 2

	plan.add_mission_task(t1)
	assert_equal(plan, t1.plan)
	t1.depends_on t2
	assert_equal(plan, t1.plan)
	assert_equal(plan, t2.plan)
	assert(plan.has_task?(t2))

	e = EventGenerator.new(true)
        t1.start_event.signals e
	assert_equal(plan, e.plan)
	assert(plan.has_free_event?(e))
    end

    # Checks that a garbage collected object (event or task) cannot be added back into the plan
    def test_removal_is_final
	t = Roby::Tasks::Simple.new
	e = EventGenerator.new(true)
	plan.real_plan.add [t, e]
        plan.real_plan.remove_task(t)
        plan.real_plan.remove_free_event(e)
	assert_raises(ArgumentError) { plan.add(t) }
        assert !plan.has_task?(t)
	assert_raises(ArgumentError) { plan.add(e) }
        assert !plan.has_free_event?(e)
    end

    def test_proxy_operator
        t = Roby::Tasks::Simple.new
        assert_same t, plan[t, create: false]

        assert plan.has_task?(t)
        assert_same t, plan[t, create: true]

        plan.remove_task(t)
        assert_raises(ArgumentError) { plan[t] }
    end

    def test_task_finalized_called_on_clear
        plan.add(task = Roby::Task.new)
        flexmock(task).should_receive(:finalized!).once
        task.each_event do |ev|
            flexmock(ev).should_receive(:finalized!).once
        end
        plan.clear
    end

    def test_event_finalized_called_on_clear
        plan.add(ev = Roby::EventGenerator.new)
        flexmock(ev).should_receive(:finalized!).once
        plan.clear
    end

    def test_task_events_are_added_and_removed
        plan.add(task = Roby::Tasks::Simple.new)
        task.each_event do |ev|
            assert(plan.has_task_event?(ev))
        end
        plan.remove_task(task)
        task.each_event do |ev|
            assert(!plan.has_task_event?(ev))
        end
    end

    def test_task_events_are_removed_on_clear
        plan.add(task = Roby::Tasks::Simple.new)
        plan.clear
        task.each_event do |ev|
            assert(!plan.has_task_event?(ev))
        end
    end
end

class TC_Plan < Minitest::Test
    include TC_PlanStatic

    def test_transaction_stack
        assert_equal [plan], plan.transaction_stack
    end


    def test_quarantine
        t1, t2, t3, p = prepare_plan add: 4
        t1.depends_on t2
        t2.depends_on t3
        t2.planned_by p

        t1.start_event.signals p.start_event
        t2.success_event.signals p.start_event

        plan.add(t2)
        with_log_level(Roby, Logger::FATAL) do
            plan.quarantine(t2)
        end
        assert_equal([t2], plan.gc_quarantine.to_a)
        assert(t2.leaf?)
        assert(t2.success_event.leaf?)

        plan.remove_task(t2)
        assert(plan.gc_quarantine.empty?)
    end
    
    def test_failed_mission
        t1, t2, t3, t4 = prepare_plan add: 4, model: Tasks::Simple
        t1.depends_on t2
        t2.depends_on t3
        t3.depends_on t4

        plan.add_mission_task(t2)
        t1.start!
        t2.start!
        t3.start!
        t4.start!
        error = assert_raises(SynchronousEventProcessingMultipleErrors) { t4.stop! }
        errors = error.errors
        assert_equal 2, errors.size
        child_failed   = errors.find { |e, _| e.exception.kind_of?(ChildFailedError) }
        mission_failed = errors.find { |e, _| e.exception.kind_of?(MissionFailedError) }

        assert child_failed
        assert_equal t4, child_failed.first.origin
        assert mission_failed
        assert_equal t2, mission_failed.first.origin
    end
end

module Roby
    describe Plan do
        describe "#initialize" do
            it "instanciates graphs for all the relation graphs registered on Roby::Task" do
                space = flexmock(instanciate: Hash[1 => 2])
                flexmock(Roby::Task).should_receive(:all_relation_spaces).and_return([space])
                plan = Roby::Plan.new
                assert_equal Hash[1 => 2], plan.task_relation_graphs
            end
            it "instanciates graphs for all the relation graphs registered on Roby::Task's submodels" do
                root_space = flexmock(instanciate: Hash[1 => 2])
                submodel_space = flexmock(instanciate: Hash[41 => 42])
                task_m = Roby::Task.new_submodel
                flexmock(Roby::Task).should_receive(:all_relation_spaces).and_return([root_space, submodel_space])
                plan = Roby::Plan.new
                assert_equal Hash[1 => 2, 41 => 42], plan.task_relation_graphs
            end
            it "configures #task_relation_graphs to raise if an invalid graph is being resolved" do
                space = flexmock
                flexmock(Roby::Task).should_receive(:all_relation_spaces).and_return([space])
                assert_raises(ArgumentError) do
                    plan.task_relation_graphs[invalid = flexmock]
                end
            end
            it "configures #task_relation_graphs to return nil if nil is being resolved" do
                plan = Roby::Plan.new
                assert_equal nil, plan.task_relation_graphs[nil]
            end

            it "instanciates graphs for all the relation graphs registered on Roby::EventGenerator" do
                space = flexmock(instanciate: Hash[1 => 2])
                flexmock(Roby::EventGenerator).should_receive(:all_relation_spaces).and_return([space])
                plan = Roby::Plan.new
                assert_equal Hash[1 => 2], plan.event_relation_graphs
            end
            it "configures #event_relation_graphs to raise if an invalid graph is being resolved" do
                space = flexmock
                flexmock(Roby::EventGenerator).should_receive(:all_relation_spaces).and_return([space])
                assert_raises(ArgumentError) do
                    plan.event_relation_graphs[invalid = flexmock]
                end
            end
            it "configures #task_relation_graphs to return nil if nil is being resolved" do
                plan = Roby::Plan.new
                assert_equal nil, plan.event_relation_graphs[nil]
            end
        end
        describe "#locally_useful_tasks" do
            it "computes the merge of all strong relation graphs from permanent tasks" do
                parent, (child, planner, planner_child) = prepare_plan permanent: 1, add: 3, model: Roby::Tasks::Simple
                parent.depends_on child
                child.planned_by planner
                planner.depends_on planner_child
                assert_equal [parent, child, planner, planner_child].to_set, plan.locally_useful_tasks
            end
            it "ignores tasks that are not used by a permanent task" do
                parent, (other_root, child, planner, planner_child) = prepare_plan permanent: 1, add: 4, model: Roby::Tasks::Simple
                parent.depends_on child
                child.planned_by planner
                planner.depends_on planner_child
                other_root.depends_on planner
                assert_equal [parent, child, planner, planner_child].to_set, plan.locally_useful_tasks
            end

            it "returns standalone mission tasks" do
                parent = prepare_plan missions: 1, model: Roby::Tasks::Simple
                assert_equal [parent].to_set, plan.locally_useful_tasks
            end

            it "returns standalone permanent tasks" do
                parent = prepare_plan permanent: 1, model: Roby::Tasks::Simple
                assert_equal [parent].to_set, plan.locally_useful_tasks
            end

            it "computes the merge of all strong relation graphs from mission tasks" do
                parent, (child, planner, planner_child) = prepare_plan missions: 1, add: 3, model: Roby::Tasks::Simple
                parent.depends_on child
                child.planned_by planner
                planner.depends_on planner_child
                assert_equal [parent, child, planner, planner_child].to_set, plan.locally_useful_tasks
            end
            it "ignores tasks that are not used by a missions" do
                parent, (other_root, child, planner, planner_child) = prepare_plan missions: 1, add: 4, model: Roby::Tasks::Simple
                parent.depends_on child
                child.planned_by planner
                planner.depends_on planner_child
                other_root.depends_on planner
                assert_equal [parent, child, planner, planner_child].to_set, plan.locally_useful_tasks
            end
        end

        describe "#add_trigger" do
            attr_reader :task_m, :task, :recorder
            before do
                @task_m = Roby::Task.new_submodel
                @task   = task_m.new
                @recorder = flexmock
            end
            it "yields new tasks that match the given object" do
                recorder.should_receive(:called).once.with(task)
                plan.add_trigger task_m do |task|
                    recorder.called(task)
                end
                plan.add task
            end
            it "does not yield new tasks that do not match the given object" do
                recorder.should_receive(:called).never
                plan.add_trigger task_m.query.abstract do |task|
                    recorder.called(task)
                end
                plan.add task
            end
            it "yields tasks whose modifications within the transaction created a match" do
                recorder.should_receive(:called).once.with(task)
                plan.add_trigger task_m.query.mission do |task|
                    recorder.called(task)
                end
                plan.add task
                plan.in_transaction do |trsc|
                    trsc.add_mission_task trsc[task]
                    trsc.commit_transaction
                end
            end
            it "yields tasks added by applying a transaction" do
                recorder.should_receive(:called).once.with(task)
                plan.add_trigger task_m do |task|
                    recorder.called(task)
                end
                plan.in_transaction do |trsc|
                    trsc.add task
                    trsc.commit_transaction
                end
            end
            it "yields matching tasks that already are in the plan" do
                recorder.should_receive(:called).once
                plan.add task
                plan.add_trigger task_m do |task|
                    recorder.called(task)
                end
            end
            it "does not yield not matching tasks that already are in the plan" do
                recorder.should_receive(:called).never
                plan.add task
                plan.add_trigger task_m.query.abstract do |task|
                    recorder.called(task)
                end
            end
        end

        describe "#remove_trigger" do
            attr_reader :task_m, :task, :recorder
            before do
                @task_m = Roby::Task.new_submodel
                @task   = task_m.new
                @recorder = flexmock
            end
            it "allows to remove a trigger added by #add_trigger" do
                trigger = plan.add_trigger task_m do |task|
                    recorder.called
                end
                plan.remove_trigger trigger
                recorder.should_receive(:called).never
                plan.add task
            end
        end

        describe "#compute_subplan_replacement" do
            attr_reader :graph
            before do
                @graph = Roby::Relations::Graph.new
            end
            it "moves relations for which the source is not a key in the task mapping" do
                plan.add(parent = Roby::Task.new)
                plan.add(source = Roby::Task.new)
                plan.add(target = Roby::Task.new)
                graph.add_edge(parent, source, info = flexmock)
                new, removed = plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [[graph, parent, target, info]], new
                assert_equal [[graph, parent, source]], removed
            end
            it "moves relations for which the target is not a key in the task mapping" do
                plan.add(source = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(target = Roby::Task.new)
                graph.add_edge(source, child, info = flexmock)
                new, removed = plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [[graph, target, child, info]], new
                assert_equal [[graph, source, child]], removed
            end
            it "ignores relations if both objects are within the mapping" do
                plan.add(parent = Roby::Task.new)
                plan.add(parent_target = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(child_target = Roby::Task.new)
                graph.add_edge(parent, child, flexmock)
                new, removed = plan.compute_subplan_replacement(Hash[parent => parent_target, child => child_target], [graph])
                assert_equal [], new
                assert_equal [], removed
            end
            it "ignores relations involving parents that are not mapped" do
                plan.add(root = Roby::Task.new)
                plan.add(parent = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(child_target = Roby::Task.new)
                graph.add_edge(root, parent, flexmock)
                graph.add_edge(parent, child, flexmock)
                new, removed = plan.compute_subplan_replacement(Hash[parent => nil, child => child_target], [graph])
                assert_equal [], new
                assert_equal [], removed
            end
            it "accept a resolver object" do
                plan.add(parent = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(child_target = Roby::Task.new)
                graph.add_edge(parent, child, info = flexmock)
                mapping = Hash[child => child_target]
                resolver = ->(t) { mapping[t] }
                new, removed = plan.compute_subplan_replacement(
                    Hash[child => [nil, resolver]], [graph])
                assert_equal [[graph, parent, child_target, info]], new
                assert_equal [[graph, parent, child]], removed
            end
            it "ignores child objects if child_objects is false" do
                plan.add(parent = Roby::Task.new)
                plan.add(child = Roby::Task.new)
                plan.add(parent_target = Roby::Task.new)
                graph.add_edge(parent, child, flexmock)
                new, removed = plan.compute_subplan_replacement(
                    Hash[parent => parent_target], [graph], child_objects: false)
                assert_equal [], new
                assert_equal [], removed
            end
            it "ignores strong relations" do
                plan.add(parent = Roby::Task.new)
                plan.add(source = Roby::Task.new)
                plan.add(target = Roby::Task.new)
                graph = Roby::Relations::Graph.new(strong: true)
                graph.add_edge(parent, source, info = flexmock)
                new, removed = plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [], new
                assert_equal [], removed
            end
            it "copies relations instead of moving them if the graph is copy_on_replace" do
                plan.add(parent = Roby::Task.new)
                plan.add(source = Roby::Task.new)
                plan.add(target = Roby::Task.new)
                graph = Roby::Relations::Graph.new(copy_on_replace: true)
                graph.add_edge(parent, source, info = flexmock)
                new, removed = plan.compute_subplan_replacement(Hash[source => target], [graph])
                assert_equal [[graph, parent, target, info]], new
                assert_equal [], removed
            end
        end

        describe "#unneeded_events" do
            it "returns free events that are connected to nothing" do
                plan.add(ev = Roby::EventGenerator.new)
                assert_equal [ev].to_set, plan.unneeded_events.to_set
            end
            it "does not return free events that are reachable from a permanent event" do
                plan.add_permanent_event(ev = Roby::EventGenerator.new)
                assert plan.unneeded_events.empty?
            end
            it "does not return free events that are reachable from a task event" do
                plan.add(t = Roby::Task.new)
                ev = Roby::EventGenerator.new
                t.start_event.forward_to ev
                assert plan.unneeded_events.empty?
            end
            it "does not return free events that can reach a task event" do
                plan.add(t = Roby::Task.new)
                ev = Roby::EventGenerator.new
                ev.forward_to t.start_event
                assert plan.unneeded_events.empty?
            end
        end
        
        describe "deep_copy" do
            it "copies the plan objects and their structure" do
                parent, (child, planner) = prepare_plan missions: 1, add: 2, model: Roby::Tasks::Simple
                plan.add(ev = Roby::EventGenerator.new)

                child.success_event.forward_to ev
                parent.depends_on child
                child.planned_by planner

                copy, mappings = plan.deep_copy
                assert_equal (plan.tasks | plan.free_events | plan.task_events), mappings.keys.to_set
                assert plan.same_plan?(copy, mappings)
            end
        end

        describe "#useful_events" do
            it "considers standalone events as not useful" do
                plan.add(parent = EventGenerator.new(true))
                plan.add(child = EventGenerator.new(true))
                parent.signals child
                assert plan.useful_events.empty?
            end
            it "considers permanent events useful" do
                plan.add_permanent_event(ev = EventGenerator.new(true))
                assert_equal [ev], plan.useful_events.to_a
            end
            it "considers events parent of permanent events as useful" do
                plan.add(parent = EventGenerator.new(true))
                plan.add_permanent_event(child = EventGenerator.new(true))
                parent.signals child
                assert [parent, child].to_set, plan.useful_events.to_set
            end
            it "considers events parent of task events as useful" do
                plan.add(parent = EventGenerator.new(true))
                plan.add(task = Roby::Task.new)
                parent.forward_to task.start_event
                assert [parent].to_set, plan.useful_events.to_set
            end
            it "considers events children of permanent events as useful" do
                plan.add_permanent_event(parent = EventGenerator.new(true))
                plan.add(child = EventGenerator.new(true))
                parent.signals child
                assert [parent, child].to_set, plan.useful_events.to_set
            end
            it "considers events children of task events as useful" do
                plan.add(child = EventGenerator.new(true))
                plan.add(task = Roby::Task.new)
                task.start_event.forward_to child
                assert [child].to_set, plan.useful_events.to_set
            end
            it "considers any event linked to another useful event useful" do
                plan.add_permanent_event(parent_1 = EventGenerator.new)
                plan.add(parent_2 = EventGenerator.new)
                plan.add(aggregator = EventGenerator.new)
                parent_1.forward_to aggregator
                parent_2.forward_to aggregator
                assert [parent_1, parent_2, aggregator].to_set, plan.useful_events.to_set
            end
        end

        describe "#same_plan?" do
            attr_reader :plan, :copy
            before do
                @plan = Plan.new
                @copy = Plan.new
            end

            def prepare_mappings(mappings)
                task_event_mappings = Hash.new
                mappings.each do |original, copy|
                    if original.respond_to?(:each_event)
                        original.each_event do |ev|
                            task_event_mappings[ev] = copy.event(ev.symbol)
                        end
                    end
                end
                task_event_mappings.merge(mappings)
            end

            it "returns true on two empty plans" do
                plan.same_plan?(copy, Hash.new)
            end

            it "returns true on a plan with a single task" do
                plan.add(task = Task.new)
                copy.add(task_copy = Task.new)
                mappings = prepare_mappings(task => task_copy)
                assert plan.same_plan?(copy, mappings)
            end

            it "returns true on a plan with a single event" do
                plan.add(event = EventGenerator.new)
                copy.add(event_copy = EventGenerator.new)
                mappings = prepare_mappings(event => event_copy)
                assert plan.same_plan?(copy, mappings)
            end

            it "returns true on a plan with identical task relations" do
                plan.add(task_parent = Task.new)
                task_parent.depends_on(task_child = Task.new)
                copy.add(task_parent_copy = Task.new)
                task_parent_copy.depends_on(task_child_copy = Task.new)
                mappings = prepare_mappings(task_parent => task_parent_copy, task_child => task_child_copy)
                assert plan.same_plan?(copy, mappings)
            end

            it "returns false for a plan with differing task relations" do
                plan.add(task_parent = Task.new)
                task_parent.depends_on(task_child = Task.new)
                copy.add(task_parent_copy = Task.new)
                copy.add(task_child_copy = Task.new)
                mappings = prepare_mappings(task_parent => task_parent_copy, task_child => task_child_copy)
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns false for a plan with a missing task" do
                plan.add(task = Task.new)
                assert !plan.same_plan?(copy, Hash.new)
            end

            it "returns false if the plans mission sets differ" do
                plan.add_mission_task(task = Task.new)
                copy.add(task_copy = Task.new)
                mappings = prepare_mappings(task => task_copy)
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns false if the plans permanent tasks differ" do
                plan.add_permanent_task(task = Task.new)
                copy.add(task_copy = Task.new)
                mappings = prepare_mappings(task => task_copy)
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns false if the plans permanent events differ" do
                plan.add_permanent_event(event = EventGenerator.new)
                copy.add(event_copy = EventGenerator.new)
                mappings = prepare_mappings(event => event_copy)
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns true on a plan with identical event relations" do
                plan.add(event_parent = EventGenerator.new)
                event_parent.add_signal(event_child = EventGenerator.new)
                copy.add(event_parent_copy = EventGenerator.new)
                event_parent_copy.add_signal(event_child_copy = EventGenerator.new)
                mappings = prepare_mappings(event_parent => event_parent_copy, event_child => event_child_copy)
                assert plan.same_plan?(copy, mappings)
            end

            it "returns false on a plan with differing event relations" do
                plan.add(event_parent = EventGenerator.new)
                event_parent.add_signal(event_child = EventGenerator.new)
                copy.add(event_parent_copy = EventGenerator.new)
                copy.add(event_child_copy = EventGenerator.new)
                mappings = prepare_mappings(event_parent => event_parent_copy, event_child => event_child_copy)
                assert !plan.same_plan?(copy, mappings)
            end

            it "returns false on a plan with differing task event relations" do
                plan.add(task_parent = Task.new)
                plan.add(task_child = Task.new)
                copy.add(task_parent_copy = Task.new)
                copy.add(task_child_copy = Task.new)
                task_parent.start_event.forward_to task_child.start_event
                mappings = prepare_mappings(task_parent => task_parent_copy, task_child => task_child_copy)
                assert !plan.same_plan?(copy, mappings)
            end
        end
    end
end

