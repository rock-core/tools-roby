# frozen_string_literal: true

require "roby/test/self"
require "roby/tasks/simple"

require "./test/test_plan"

# Check that a transaction behaves like a plan
class TC_TransactionAsPlan < Minitest::Test
    include Roby::PlanCommonBehavior
    include Roby::SelfTest

    attr_reader :real_plan
    attr_reader :plan
    def engine
        (real_plan || plan).engine
    end

    def setup
        super
        @real_plan = Roby::Plan.new
        @plan = Transaction.new(real_plan)
    end

    def teardown
        if real_plan
            @plan.discard_transaction
            real_plan.clear
            @real_plan = plan
        end
        super
    end
end

module TC_TransactionBehaviour
    Dependency = Roby::TaskStructure::Dependency
    PlannedBy = Roby::TaskStructure::PlannedBy
    Signal = Roby::EventStructure::Signal
    Forwarding = Roby::EventStructure::Forwarding

    Tasks = Roby::Tasks

    def execute(plan: self.plan)
        if plan.kind_of?(Roby::ExecutablePlan)
            super
        else
            yield
        end
    end

    def test_wrap_task
        plan.add(t = Tasks::Simple.new)
        plan.add(t_child = Tasks::Simple.new)
        plan.add(t_parent = Tasks::Simple.new)
        t.depends_on t_child, model: Roby::Task
        t_parent.depends_on t
        transaction_commit(plan) do |trsc|
            assert !trsc[t, create: false]
            assert trsc.tasks.empty?

            assert(proxy = trsc[t, create: true])
            assert(trsc.has_task?(proxy))
            assert_same(proxy, trsc[t, create: false])

            assert_equal [], proxy.parent_objects(Dependency).to_a
            assert_equal [], proxy.child_objects(Dependency).to_a

            child_proxy = trsc[t_child]
            assert_equal t[t_child, Dependency], proxy[child_proxy, Dependency]
        end
    end

    def test_wrap_task_event
        plan.add(t1 = Tasks::Simple.new)
        plan.add(t2 = Tasks::Simple.new)
        old_start = t1.start_event
        transaction_commit(plan) do |trsc|
            t_proxy = trsc[t2]
            proxy   = t_proxy.event(:start)
            assert_same(proxy, trsc[t2.event(:start), create: false])
            assert_equal(trsc, proxy.plan)

            assert(proxy = trsc[t1.event(:start)])
            assert_equal(proxy, trsc[t1].event(:start))
            assert_same(proxy, trsc[t1.event(:start)])
            assert_equal(trsc, proxy.plan)
        end

        assert_equal [t1, t2].to_set, plan.tasks
        assert_same old_start, t1.start_event
    end

    def test_wrapping_task_events_copies_their_relations
        plan.add(t = Roby::Task.new)
        assert_child_of t.start_event, t.updated_data_event, Roby::EventStructure::Precedence
        transaction_commit(plan) do |trsc|
            proxy = trsc[t]
            assert_child_of proxy.start_event, proxy.updated_data_event, Roby::EventStructure::Precedence
        end
    end

    def test_wrapping_a_task_copies_relations_between_its_events_and_the_tasks_outside
        plan.add(parent = Roby::Task.new)
        plan.add(task = Roby::Task.new)
        plan.add(child = Roby::Task.new)
        parent.start_event.signals task.start_event
        task.start_event.signals child.start_event

        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            # NOTE: it is important that we wrap the task here AFTER the two
            # other as we are testing the relation copy, which is directional
            p_task = trsc[task]
            assert_child_of p_parent.start_event, p_task.start_event, Roby::EventStructure::Signal
            assert_child_of p_task.start_event, p_child.start_event, Roby::EventStructure::Signal
        end
    end

    def test_may_unwrap
        plan.add(t = Tasks::Simple.new)
        transaction_commit(plan, t) do |trsc, p|
            assert_equal t, trsc.may_unwrap(p)
            assert_equal t.event(:start), trsc.may_unwrap(p.event(:start))

            t = Tasks::Simple.new
            assert_equal t, trsc.may_unwrap(t)
        end
    end

    def test_remove_task
        plan.add(t = Tasks::Simple.new)
        transaction_commit(plan, t) do |trsc, p|
            trsc.remove_task(p)
            assert_same(nil, trsc[t, create: false])
            assert(!trsc.has_task?(p))
        end

        t1, t2, t3 = prepare_plan missions: 1, add: 1, tasks: 1
        t1.depends_on t2
        transaction_commit(plan, t1, t2) do |trsc, p1, p2|
            p1.depends_on(t3)
            trsc.remove_task(p1)
            refute_same p1, trsc[t1]
        end
        assert(plan.has_task?(t1))
        assert_equal([t2], t1.children.to_a)

        t3 = Tasks::Simple.new
        transaction_commit(plan, t1, t2) do |trsc, p1, p2|
            p1.depends_on t3
            p1.remove_child p2
            trsc.remove_task(p1)
        end
        assert(plan.has_task?(t1))
        assert_equal([t2], t1.children.to_a)

        t = nil
        plan.in_transaction do |trsc|
            trsc.add(t = Roby::Task.new)
            trsc.remove_task(t)
        end
        assert(!plan.has_task?(t))
    end

    def test_add_tasks_from_plan
        plan.add(t = Tasks::Simple.new)
        transaction_commit(plan) do |trsc|
            assert_raises(Roby::ModelViolation) { trsc.add(t) }
        end
    end

    def test_object_transaction_stack
        plan.add(t = Tasks::Simple.new)
        transaction_commit(plan, t) do |trsc1, p1|
            assert_equal([trsc1, plan], p1.transaction_stack)
            transaction_commit(trsc1, p1) do |trsc2, p2|
                assert_equal([trsc2, trsc1, plan], p2.transaction_stack)
            end
        end
    end

    def test_merged_relations
        t1, t2, t3 = prepare_plan add: 3
        t1.depends_on t2
        t2.depends_on t3

        transaction_commit(plan, t2) do |trsc, p2|
            assert_equal [t1], p2.merged_relations(:each_parent_task, true).map(&:__getobj__)
            assert_equal [t3], p2.merged_relations(:each_child, true).map(&:__getobj__)
        end

        transaction_commit(plan, t2) do |trsc, p2|
            assert_equal [[t2, t1]], p2.merged_relations(:each_parent_task, false).to_a
            assert_equal [[t2, t3]], p2.merged_relations(:each_child, false).to_a
            assert !trsc[t1, create: false]
            assert !trsc[t3, create: false]
        end
    end

    def transaction_op(plan, op, *needed_proxies)
        trsc = Roby::Transaction.new(plan)
        proxies = needed_proxies.map do |o|
            plan.add(o) unless o.plan

            p = trsc[o]
            refute_equal(p, o)
            p
        end
        yield(trsc, *proxies)

        # Check that no task in trsc are in plan, and that no task of plan are in trsc
        assert((trsc.tasks & plan.tasks).empty?, (trsc.tasks & plan.tasks).to_a.map(&:to_s).join("\n  "))

        plan = trsc.plan
        trsc.send(op)
        assert(!trsc.plan)
        assert(plan.transactions.empty?)

        plan.each_event_relation_graph do |g|
            g.each_vertex do |v|
                assert_kind_of(Roby::EventGenerator, v)
            end
        end

        plan.each_task_relation_graph do |g|
            g.each_vertex do |v|
                assert_kind_of(Roby::Task, v)
            end
        end

        plan.tasks.each do |t|
            assert_kind_of(Roby::Task, t, t.class.ancestors.inspect)
        end
    rescue
        trsc.discard_transaction
        raise
    end

    def transaction_commit(plan, *needed_proxies, &block)
        transaction_op(plan, :commit_transaction, *needed_proxies, &block)
    end

    def transaction_discard(plan, *needed_proxies, &block)
        transaction_op(plan, :discard_transaction, *needed_proxies, &block)
    end

    # Checks that model-level task relations are kept if a task is modified by a transaction
    def test_commit_model_level_event_relations_in_tasks
        t = prepare_plan add: 1
        transaction_commit(plan, t) do |trsc, p|
            trsc.add(p)
            assert(p.event(:start).child_object?(p.event(:updated_data), Roby::EventStructure::Precedence))
            assert(p.event(:failed).child_object?(p.event(:stop), Roby::EventStructure::Forwarding))
        end
        assert(t.event(:start).child_object?(t.event(:updated_data), Roby::EventStructure::Precedence))
        assert(t.event(:failed).child_object?(t.event(:stop), Roby::EventStructure::Forwarding))

        t = prepare_plan add: 1
        transaction_commit(plan, t) do |trsc, p|
            trsc.add_mission_task(p)
        end
        assert(t.event(:start).child_object?(t.event(:updated_data), Roby::EventStructure::Precedence))
        assert(t.event(:failed).child_object?(t.event(:stop), Roby::EventStructure::Forwarding))
    end

    def test_commit_abstract_flag
        t = prepare_plan add: 1
        sequence = [true, false]

        t.abstract = false
        sequence.each do |value|
            original = t.abstract?
            refute_equal(value, original)
            transaction_commit(plan, t) do |trsc, p|
                assert_equal(original, p.abstract?)
                p.abstract = value
            end
            assert_equal(value, t.abstract?)
        end
    end

    def test_commit_executable_flag
        t = prepare_plan add: 1
        sequence = [true, nil, false, nil, true, false]

        t.executable = false
        sequence.each do |value|
            transaction_commit(plan, t) do |trsc, p|
                p.executable = value
            end
            if value.nil?
                assert_nil(t.instance_variable_get(:@executable))
            else
                assert_equal(value, t.instance_variable_get(:@executable))
            end
        end
    end

    def test_commit_arguments
        (t1, t2), t = prepare_plan add: 2, tasks: 1
        t1.arguments[:first] = 10
        transaction_commit(plan, t1, t2) do |trsc, p1, p2|
            p1.arguments[:first] = 20
            p1.arguments[:second] = p2
            trsc.add(t)
            t.arguments[:task] = p2
        end

        assert_equal(20, t1.arguments[:first])
        assert_equal(t2, t1.arguments[:second])
        assert_equal(t2, t.arguments[:task])

        transaction_discard(plan, t1, t2) do |trsc, p1, p2|
            p1.arguments[:first] = 10
            assert_equal(p2, p1.arguments[:second])
        end

        assert_equal(20, t1.arguments[:first])
        assert_equal(t2, t1.arguments[:second])
    end

    def test_finalization_handlers_are_not_called_at_commit
        t = prepare_plan add: 1
        FlexMock.use do |mock|
            t.when_finalized do |task|
                mock.old_handler(task)
            end
            transaction_commit(plan, t) do |trsc, p|
                p.when_finalized do |task|
                    mock.new_handler
                end
            end
            mock.should_receive(:old_handler).never
            mock.should_receive(:new_handler).never
        end
    end

    def test_wraps_plan_service
        t = prepare_plan add: 1
        service = Roby::PlanService.get(t)
        transaction_commit(plan, t) do |trsc, p|
            assert(service_proxy = trsc.find_plan_service(p))
            assert_equal(p, service_proxy.task)
            assert(service_proxy.transaction_proxy?)
            assert_equal(service, service_proxy.__getobj__)
        end
    end

    def test_create_plan_service
        t = prepare_plan add: 1
        service = nil
        transaction_commit(plan, t) do |trsc, p|
            service = Roby::PlanService.get(p)
            assert_equal(service, trsc.find_plan_service(p))
            assert_equal(p, service.task)
            assert(!service.transaction_proxy?)
        end
        assert_equal(service, plan.find_plan_service(t))
    end

    def test_moves_plan_services_to_new_task
        t = prepare_plan add: 1
        service = Roby::PlanService.get(t)
        t2 = nil
        transaction_commit(plan, t) do |trsc, p|
            trsc.add(t2 = Roby::Task.new)
            trsc.replace(p, t2)
        end

        assert(!plan.find_plan_service(t))
        assert_equal(service, plan.find_plan_service(t2))
        assert_equal(t2, service.task)
    end

    def test_moves_plan_services_from_new_task
        t = prepare_plan add: 1
        service, t2 = nil
        transaction_commit(plan, t) do |trsc, p|
            trsc.add(t2 = Roby::Task.new)
            service = Roby::PlanService.get(t2)
            assert(trsc.find_plan_service(t2))
            trsc.replace(t2, p)
        end

        assert_equal(service, plan.find_plan_service(t))
        assert(!plan.find_plan_service(t2))
        assert_equal(t, service.task)
    end

    def test_moves_plan_services_between_tasks
        t1, t2 = prepare_plan add: 2
        service = Roby::PlanService.get(t1)

        transaction_commit(plan, t1, t2) do |trsc, p1, p2|
            trsc.replace(p1, p2)
        end

        assert(!plan.find_plan_service(t1))
        assert_equal(service, plan.find_plan_service(t2))
        assert_equal(t2, service.task)
    end

    def test_mission_proxy_is_a_mission_and_stays_a_mission
        task = prepare_plan missions: 1
        transaction_commit(plan, task) do |trsc, proxy|
            assert trsc.mission_task?(proxy)
        end
        assert plan.mission_task?(task)
    end

    def test_replacing_a_mission_with_a_new_task_makes_the_replacement_a_mission
        task, replacement = prepare_plan missions: 1, tasks: 1
        transaction_commit(plan, task) do |trsc, proxy|
            trsc.replace(proxy, replacement)
        end
        assert !plan.mission_task?(task)
        assert plan.mission_task?(replacement)
    end

    def test_replacing_a_mission_with_an_existing_task_makes_the_replacement_a_mission
        task, replacement = prepare_plan missions: 1, add: 1
        transaction_commit(plan, task, replacement) do |trsc, p_task, p_replacement|
            trsc.replace(p_task, p_replacement)
        end
        assert !plan.mission_task?(task)
        assert plan.mission_task?(replacement)
    end

    def test_a_new_mission_is_added_to_the_plan_as_a_mission
        task = prepare_plan tasks: 1
        transaction_commit(plan) do |trsc|
            trsc.add_mission_task(task)
        end
        assert plan.mission_task?(task)
    end

    def test_commit_unmarks_a_mission
        task = prepare_plan missions: 1
        transaction_commit(plan, task) do |trsc, proxy|
            trsc.unmark_mission_task(proxy)
            assert !trsc.mission_task?(proxy)
            assert plan.mission_task?(task)
        end
        assert !plan.mission_task?(task)
    end

    def test_remove_task_in_transaction_cancels_modifications_to_the_mission_flag
        task = prepare_plan missions: 1
        transaction_commit(plan, task) do |trsc, proxy|
            trsc.unmark_mission_task(proxy)
            trsc.remove_task(proxy)
        end
        assert plan.mission_task?(task)
    end

    def test_permanent_proxy_is_a_permanent_and_stays_a_permanent
        task = prepare_plan permanent: 1
        transaction_commit(plan, task) do |trsc, proxy|
            assert trsc.permanent_task?(proxy)
        end
        assert plan.permanent_task?(task)
    end

    def test_a_new_permanent_is_added_to_the_plan_as_a_permanent
        task = prepare_plan tasks: 1
        transaction_commit(plan) do |trsc|
            trsc.add_permanent_task(task)
        end
        assert plan.permanent_task?(task)
    end

    def test_commit_unmarks_a_permanent
        task = prepare_plan permanent: 1
        transaction_commit(plan, task) do |trsc, proxy|
            trsc.unmark_permanent_task(proxy)
            assert !trsc.permanent_task?(task)
            assert plan.permanent_task?(task)
        end
        assert !plan.permanent_task?(task)
    end

    def test_remove_task_in_transaction_cancels_modifications_to_the_permanent_flag
        task = prepare_plan permanent: 1
        transaction_commit(plan, task) do |trsc, proxy|
            trsc.unmark_permanent_task(proxy)
            trsc.remove_task(proxy)
        end
        assert plan.permanent_task?(task)
    end

    def test_it_can_wrap_an_existing_free_event
        plan.add(ev = Roby::EventGenerator.new)
        transaction_commit(plan, ev) do |trsc, p_ev|
            assert trsc.has_free_event?(p_ev)
        end
    end

    # Tests insertion and removal of free events
    def test_commit_plan_events
        e1, e2 = (1..2).map { Roby::EventGenerator.new }
        plan.add_permanent_event(e1)
        plan.add(e2)

        transaction_commit(plan, e1, e2) do |trsc, p1, p2|
            assert(trsc.has_free_event?(p1))
            assert(trsc.permanent_event?(p1))
            assert(trsc.has_free_event?(p2))
            assert(!trsc.permanent_event?(p2))

            trsc.unmark_permanent_event(p1)
            assert(!trsc.permanent_event?(p1))
        end
        assert(!plan.permanent_event?(e1))

        e3, e4 = (1..2).map { Roby::EventGenerator.new }
        transaction_commit(plan) do |trsc|
            trsc.add_permanent_event(e3)
            trsc.add(e4)
            assert(trsc.permanent_event?(e3))
            assert(trsc.has_free_event?(e4))
            assert(!trsc.permanent_event?(e4))
        end
        assert(plan.has_free_event?(e3))
        assert(plan.permanent_event?(e3))
        assert(plan.has_free_event?(e4))
        assert(!plan.permanent_event?(e4))
    end

    def test_commit_adds_new_events_and_their_relations
        parent, child = (1..2).map { Roby::EventGenerator.new }
        info = flexmock
        transaction_commit(plan) do |trsc|
            trsc.add parent
            trsc.add child
            parent.add_signal child, info
        end
        assert_child_of parent, child, Signal, info
    end

    def test_commit_adds_new_tasks_and_their_relations
        parent, child = prepare_plan(tasks: 2)
        dependency_info = nil
        transaction_commit(plan) do |trsc|
            trsc.add parent
            trsc.add child
            parent.depends_on child
            dependency_info = parent[child, Dependency].dup
        end
        assert_child_of parent, child, Dependency, dependency_info
    end

    def test_commit_adds_the_relation_between_new_task_events
        task = prepare_plan(tasks: 1)
        info = flexmock
        transaction_commit(plan) do |trsc|
            trsc.add task
            task.start_event.add_signal task.stop_event, info
        end
        assert_child_of task.start_event, task.stop_event, Signal, info
    end

    def test_commit_adds_new_children_to_existing_plan_tasks
        plan_task, trsc_task = prepare_plan(add: 1, tasks: 1)
        info = nil
        transaction_commit(plan, plan_task) do |trsc, proxy|
            proxy.depends_on trsc_task
            info = proxy[trsc_task, Dependency]
        end
        assert_child_of plan_task, trsc_task, Dependency, info
    end

    def test_commit_adds_new_parents_to_existing_plan_tasks
        plan_task, trsc_task = prepare_plan(add: 1, tasks: 1)
        info = nil
        transaction_commit(plan, plan_task) do |trsc, proxy|
            trsc_task.depends_on proxy
            info = trsc_task[proxy, Dependency]
        end
        assert_child_of trsc_task, plan_task, Dependency, info
    end

    def test_commit_adds_relations_between_existing_plan_tasks
        parent, child = prepare_plan(add: 2)
        info = nil
        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            p_parent.depends_on p_child
            info = p_parent[p_child, Dependency]
        end
        assert_child_of parent, child, Dependency, info
    end

    def test_commit_updates_edge_info_between_existing_plan_tasks
        parent, child = prepare_plan(add: 2)
        parent.planned_by child, plan_early: false

        info = nil
        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            p_parent[p_child, PlannedBy] = Hash[plan_early: true]
        end
        assert_child_of parent, child, PlannedBy, Hash[plan_early: true]
    end

    def test_commit_removed_relations_between_existing_plan_tasks
        parent, child = prepare_plan(add: 2)
        parent.planned_by child, plan_early: false

        info = nil
        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            p_parent.remove_planning_task p_child
        end
        refute_child_of parent, child, PlannedBy
    end

    def test_wrapping_tasks_keep_their_relations
        parent, child = prepare_plan(add: 2)
        parent.depends_on child
        info = parent[child, Dependency]
        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            assert_child_of p_parent, p_child, Dependency, info
        end
        assert_child_of parent, child, Dependency, info
    end

    def test_wrapping_a_task_keep_its_internal_event_relations
        task = prepare_plan(add: 1)
        transaction_commit(plan, task) do |trsc, proxy|
            assert_child_of proxy.failed_event, proxy.stop_event, Forwarding
        end
        assert_child_of task.failed_event, task.stop_event, Forwarding
    end

    def test_wrapping_tasks_keep_their_events_relations
        parent, child = prepare_plan(add: 2)
        parent.start_event.add_forwarding child.stop_event, (info = flexmock)
        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            assert_child_of p_parent.start_event, p_child.stop_event, Forwarding, info
        end
        assert_child_of parent.start_event, child.stop_event, Forwarding, info
    end

    def test_removing_a_proxy_in_a_transaction_cancels_any_change_affecting_it
        parent, child = prepare_plan(add: 2)
        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            p_parent.depends_on p_child
            trsc.remove_task(p_child)
        end
        refute_child_of parent, child, Dependency
    end

    def test_commit_modified_relations
        (t1, t2) = prepare_plan(add: 2)
        flexmock(t1.relation_graph_for(Dependency))
            .should_receive(:merge_info)
            .and_return { |a, b| a.merge(b) }

        t1.add_child(t2, Hash[0, 1, 2, 3])
        transaction_commit(plan, t1, t2) do |trsc, p1, p2|
            flexmock(p1.relation_graph_for(Dependency))
                .should_receive(:merge_info)
                .and_return { |_, _, a, b| a.merge(b) }
            p1.add_child(p2, Hash[0, 5, 4, 5])
            assert_equal Hash[0, 5, 2, 3, 4, 5], p1[p2, Dependency]
            assert_equal Hash[0, 1, 2, 3], t1[t2, Dependency]
        end
        assert_equal Hash[0, 5, 2, 3, 4, 5], t1[t2, Dependency]

        transaction_commit(plan, t1, t2) do |trsc, p1, p2|
            p1[p2, Dependency] = Hash[0, 5, 4, 5]
            assert_equal Hash[0, 5, 4, 5], p1[p2, Dependency]
            assert_equal Hash[0, 5, 2, 3, 4, 5], t1[t2, Dependency]
        end
        assert_equal Hash[0, 5, 4, 5], t1[t2, Dependency]
    end

    def test_commit_new_events
        e1, e2 = (1..4).map { |ev| Roby::EventGenerator.new }
        transaction_commit(plan) do |trsc|
            trsc.add(e1)
            trsc.add_permanent_event(e2)
        end
        assert plan.has_free_event?(e1)
        assert plan.has_free_event?(e2)
        assert !plan.permanent_event?(e1)
        assert plan.permanent_event?(e2)
    end

    def test_commit_keeps_existing_task_event_relations_unchanged
        parent, child = prepare_plan add: 2
        parent.start_event.add_forwarding child.stop_event, (info = flexmock)
        transaction_commit(plan, parent, child) do |trsc, *_|
        end
        assert_child_of parent.start_event, child.stop_event, Forwarding, info
    end

    def test_commit_adds_new_parents_to_existing_task_events
        plan_task, trsc_task = prepare_plan add: 1, tasks: 1
        info = flexmock
        transaction_commit(plan, plan_task) do |trsc, proxy|
            trsc_task.stop_event.add_forwarding proxy.start_event, info
        end
        assert_child_of trsc_task.stop_event, plan_task.start_event, Forwarding, info
    end

    def test_commit_adds_new_children_to_existing_task_events
        plan_task, trsc_task = prepare_plan add: 1, tasks: 1
        info = flexmock
        transaction_commit(plan, plan_task) do |trsc, proxy|
            plan_task.stop_event.add_forwarding trsc_task.start_event, info
        end
        assert_child_of plan_task.stop_event, trsc_task.start_event, Forwarding, info
    end

    def test_commit_adds_new_relations_between_existing_task_events
        parent, child = prepare_plan add: 2
        info = flexmock
        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            p_parent.stop_event.add_forwarding p_child.start_event, info
        end
        assert_child_of parent.stop_event, child.start_event, Forwarding, info
    end

    def test_commit_removes_relations_between_existing_task_events
        parent, child = prepare_plan add: 2
        parent.stop_event.add_forwarding child.start_event

        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            p_parent.stop_event.remove_forwarding p_child.start_event
        end
        refute_child_of parent.stop_event, child.start_event, Forwarding
    end

    def test_commit_updates_edge_info_between_existing_task_events
        parent, child = prepare_plan add: 2
        parent.stop_event.add_forwarding child.start_event
        info = flexmock

        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            p_parent.stop_event[p_child.start_event, Forwarding] = info
        end
        assert_child_of parent.stop_event, child.start_event, Forwarding, info
    end

    def signal_graph
        plan.event_relation_graph_for(Signal)
    end

    def forwarding_graph
        plan.event_relation_graph_for(Forwarding)
    end

    def dependency_graph
        plan.task_relation_graph_for(Dependency)
    end

    def planned_by_graph
        plan.task_relation_graph_for(PlannedBy)
    end

    def test_commit_replace_updates_relations
        root, task, child, replacement = prepare_plan tasks: 4, model: Tasks::Simple
        root.depends_on task, model: Tasks::Simple
        task.depends_on child
        task.stop_event.signals root.stop_event
        task.start_event.signals child.start_event
        plan.add(root)

        transaction_commit(plan, root, task, child) do |trsc, p_root, p_task, p_child|
            assert_child_of p_task.stop_event, p_root.stop_event, Signal
            trsc.replace(p_task, replacement)
        end
        assert_child_of root, replacement, Dependency
        assert_child_of replacement.stop_event, root.stop_event, Signal
        refute_child_of replacement, child, Dependency
        refute_child_of replacement.stop_event, child.stop_event, Signal

        assert_child_of task, child, Dependency
        assert_child_of task.start_event, child.start_event, Signal
    end

    def test_commit_replace_copies_poll_handlers_to_new_task
        model = Roby::Task.new_submodel
        task = prepare_plan add: 1, model: model

        expected = []
        task.poll { |event| }
        task.poll(on_replace: :copy) { |event| }
        expected << task.poll_handlers[1]

        new_task = nil
        transaction_commit(plan, task) do |trsc, p|
            p.poll { |event| }
            p.poll(on_replace: :copy) { |event| }
            assert_equal 2, p.poll_handlers.size
            expected << p.poll_handlers[1]

            trsc.add(new_task = model.new)
            trsc.replace(p, new_task)
        end

        assert_equal expected.reverse, new_task.poll_handlers
    end

    def test_commit_replace_copies_poll_handlers_to_proxy
        model = Roby::Task.new_submodel
        task = prepare_plan add: 1, model: model
        plan.add(new_task = model.new)

        expected = []
        task.poll { |event| }
        task.poll(on_replace: :copy) { |event| }
        expected << task.poll_handlers[1]

        transaction_commit(plan, task, new_task) do |trsc, p, new_p|
            p.poll { |event| }
            p.poll(on_replace: :copy) { |event| }
            assert_equal 2, p.poll_handlers.size
            expected << p.poll_handlers[1]

            trsc.replace(p, new_p)
        end

        assert_equal expected.reverse, new_task.poll_handlers
    end

    def test_commit_replace_copies_poll_handlers_from_abstract
        model = Roby::Task.new_submodel
        task = prepare_plan add: 1, model: model
        task.abstract = true
        plan.add(new_task = model.new)

        expected = []
        task.poll { |event| }
        expected << task.poll_handlers[0]

        transaction_commit(plan, task, new_task) do |trsc, p, new_p|
            p.poll { |event| }
            expected << p.poll_handlers[0]

            trsc.replace(p, new_p)
        end

        assert_equal expected.reverse, new_task.poll_handlers
    end

    def test_commit_replace_copies_event_handlers_to_new_task
        model = Roby::Task.new_submodel
        task = prepare_plan add: 1, model: model

        expected = []
        task.start_event.on { |event| }
        task.start_event.on(on_replace: :copy) { |event| }
        expected << task.start_event.handlers[1]

        new_task = nil
        transaction_commit(plan, task) do |trsc, p|
            p.start_event.on { |event| }
            p.start_event.on(on_replace: :copy) { |event| }
            assert_equal 2, p.start_event.handlers.size
            expected << p.start_event.handlers[1]

            trsc.add(new_task = model.new)
            trsc.replace(p, new_task)
        end

        assert_equal expected, new_task.start_event.handlers
    end

    def test_commit_replace_copies_event_handlers_to_proxy
        model = Roby::Task.new_submodel
        task = prepare_plan add: 1, model: model
        plan.add(new_task = model.new)

        expected = []
        task.start_event.on { |event| }
        task.start_event.on(on_replace: :copy) { |event| }
        expected << task.start_event.handlers[1]

        transaction_commit(plan, task, new_task) do |trsc, p, new_p|
            p.start_event.on { |event| }
            p.start_event.on(on_replace: :copy) { |event| }
            assert_equal 2, p.start_event.handlers.size
            expected << p.start_event.handlers[1]

            trsc.replace(p, new_p)
        end

        assert_equal expected, new_task.start_event.handlers
    end

    def test_commit_replace_copies_event_handlers_from_abstract
        model = Roby::Task.new_submodel
        task = prepare_plan add: 1, model: model
        task.abstract = true
        plan.add(new_task = model.new)

        expected = []
        task.start_event.on { |event| }
        expected << task.start_event.handlers[0]

        transaction_commit(plan, task, new_task) do |trsc, p, new_p|
            p.start_event.on { |event| }
            expected << p.start_event.handlers[0]

            trsc.replace(p, new_p)
        end

        assert_equal expected, new_task.start_event.handlers
    end

    def test_relation_validation
        t1, t2 = prepare_plan add: 1, tasks: 1
        transaction_commit(plan, t1) do |trsc, p1|
            trsc.add_mission_task(t2)
            assert_equal(plan, t1.plan)
            assert_equal(trsc, p1.plan)
            assert_equal(trsc, t2.plan)
            assert_raises(RuntimeError) { t1.depends_on t2 }
            assert_equal(plan, t1.event(:start).plan)
            assert_equal(trsc, p1.event(:start).plan)
            assert_equal(trsc, t2.event(:start).plan)
            assert_raises(RuntimeError) { t1.start_event.signals t2.start_event }
        end
    end

    def test_wrap_raises_if_wrapping_a_finalized_task
        t1 = prepare_plan add: 1
        execute { plan.remove_task(t1) }

        plan.in_transaction do |trsc|
            assert_raises(ArgumentError) { trsc.wrap(t1) }
        end
    end

    def test_finalizing_a_task_invalidates_the_transaction
        t1, t2, t3 = prepare_plan missions: 1, add: 1
        t1.depends_on t2

        t3 = Tasks::Simple.new
        assert_raises(Roby::InvalidTransaction) do
            transaction_commit(plan, t1, t2) do |trsc, p1, p2|
                p1.depends_on(t3)
                assert(trsc.wrap(t1, create: false))
                execute { plan.remove_task(t1) }
                assert(trsc.invalid?)
            end
        end
    end

    def test_plan_add_remove_invalidate
        t1 = prepare_plan add: 1
        assert_raises(Roby::InvalidTransaction) do
            transaction_commit(plan, t1) do |trsc, p1|
                execute { plan.remove_task(t1) }
                assert(!plan.has_task?(t1))
                assert(trsc.invalid?)
            end
        end

        # Test for a special case: the task is removed from the transaction and
        # then removed from the plan. We should not invalidate in that case
        t1 = prepare_plan add: 1
        transaction_commit(plan, t1) do |trsc, p1|
            trsc.remove_task(p1)
            execute { plan.remove_task(t1) }
            assert(!trsc.invalid?)
        end
    end

    def test_proxy_clear_vertex_removes_all_relations_involving_the_task_when_committed
        parent, child = prepare_plan add: 2
        parent.depends_on child
        transaction_commit(plan, parent, child) do |trsc, p_parent, p_child|
            assert(p_parent.depends_on?(p_child, recursive: false))
            p_parent.clear_vertex
            assert(!p_parent.depends_on?(p_child, recursive: false))
            assert(parent.depends_on?(child, recursive: false))
        end
        assert(!parent.depends_on?(child, recursive: false))
    end

    def test_single_child_accessors_automatically_proxy_the_related_task
        plan.add(root = Roby::Task.new)
        root.executed_by(agent = Roby::Task.new_submodel { event :ready }.new)
        plan.in_transaction do |trsc|
            trsc_agent = trsc[root].execution_agent
            assert_equal trsc, trsc_agent.plan
            assert_same trsc[agent], trsc_agent
        end
    end

    def test_single_child_relations_are_updated_on_commit
        plan.add(root = Roby::Task.new)
        plan.add(agent = Roby::Task.new_submodel { event :ready }.new)
        plan.in_transaction do |trsc|
            trsc[root].executed_by trsc[agent]
            assert !root.execution_agent
            trsc.commit_transaction
        end
        assert_equal agent, root.execution_agent
        plan.in_transaction do |trsc|
            assert_equal trsc[agent], trsc[root].execution_agent
            trsc[root].remove_execution_agent trsc[agent]
            assert !trsc[root].execution_agent
            assert_equal agent, root.execution_agent
            trsc.commit_transaction
        end
        assert !root.execution_agent

        plan.in_transaction do |trsc|
            trsc[root].executed_by trsc[agent = Roby::Task.new_submodel { event :ready }.new]
            trsc.commit_transaction
        end
        assert_equal agent, root.execution_agent
    end
end

class TC_Transactions < Minitest::Test
    include TC_TransactionBehaviour
    include Roby::SelfTest

    def test_real_plan
        transaction_commit(plan) do |trsc|
            assert_equal(plan, trsc.real_plan)
        end
    end

    def test_plan_relation_update_invalidate
        t1, t2 = prepare_plan add: 2

        t1.depends_on t2
        assert_raises(Roby::InvalidTransaction) do
            transaction_commit(plan, t1, t2) do |trsc, p1, p2|
                assert(p1.child_object?(p2, Roby::TaskStructure::Dependency))
                t1.remove_child t2
                assert(trsc.invalid?)
            end
        end

        t1.depends_on t2
        transaction_commit(plan, t1, t2) do |trsc, p1, p2|
            p1.remove_child p2
            t1.remove_child t2
            assert(!trsc.invalid?)
        end

        t1.remove_child t2
        assert_raises(Roby::InvalidTransaction) do
            transaction_commit(plan, t1, t2) do |trsc, p1, p2|
                t1.depends_on(t2)
                assert(trsc.invalid?)
            end
        end

        t1.remove_child t2
        transaction_commit(plan, t1, t2) do |trsc, p1, p2|
            p1.depends_on p2
            t1.depends_on t2
            assert(!trsc.invalid?)
        end
    end

    def test_commit_finalization_handlers
        t = prepare_plan add: 1
        FlexMock.use do |mock|
            t.when_finalized do |task|
                mock.old_handler(task)
            end
            transaction_commit(plan, t) do |trsc, p|
                p.when_finalized do |task|
                    mock.new_handler(task)
                end
            end
            mock.should_receive(:old_handler).with(t).once
            mock.should_receive(:new_handler).with(t).once
            execute { plan.remove_task(t) }
        end
    end

    def test_commit_finalization_handlers_on_replace_behaviour
        model = Roby::Task.new_submodel do
            terminates
        end
        t1, t2 = prepare_plan add: 2, model: model

        FlexMock.use do |mock|
            t1.when_finalized do |task|
                mock.should_not_be_copied(task)
            end
            t1.when_finalized(on_replace: :copy) do |task|
                mock.should_be_copied(task)
            end
            t3 = nil
            transaction_commit(plan, t1, t2) do |trsc, p1, p2|
                trsc.add(t3 = model.new)
                trsc.replace(p1, p2)
                trsc.replace(p1, t3)
            end
            mock.should_receive(:should_be_copied).with(t1).once
            mock.should_receive(:should_be_copied).with(t2).once
            mock.should_receive(:should_be_copied).with(t3).once
            mock.should_receive(:should_not_be_copied).with(t1).once
            execute do
                plan.remove_task(t1)
                plan.remove_task(t2)
                plan.remove_task(t3)
            end
        end
    end

    def test_commit_finalization_handlers_on_replace_default_behaviour_for_abstract_tasks
        model = Roby::Task.new_submodel do
            terminates
        end
        plan.add(t1 = Roby::Task.new)
        plan.add(t2 = model.new)

        FlexMock.use do |mock|
            t1.when_finalized(on_replace: :drop) do |task|
                mock.should_not_be_copied(task)
            end
            t1.when_finalized do |task|
                mock.should_be_copied(task)
            end
            t3 = nil
            transaction_commit(plan, t1, t2) do |trsc, p1, p2|
                trsc.add(t3 = model.new)
                trsc.replace(p1, p2)
                trsc.replace(p1, t3)
            end
            mock.should_receive(:should_be_copied).with(t1).once
            mock.should_receive(:should_be_copied).with(t2).once
            mock.should_receive(:should_be_copied).with(t3).once
            mock.should_receive(:should_not_be_copied).with(t1).once
            execute do
                plan.remove_task(t1)
                plan.remove_task(t2)
                plan.remove_task(t3)
            end
        end
    end

    def test_plan_service_follows_replacements_done_in_transaction
        root, t1, t2 = prepare_plan add: 3, model: Tasks::Simple
        root.depends_on t1, model: Tasks::Simple
        root.depends_on t2, model: Tasks::Simple
        service = Roby::PlanService.get(t1)

        mock = flexmock
        transaction_commit(plan, t1, t2) do |trsc, p1, p2|
            service_proxy = trsc.find_plan_service(p1)
            service_proxy.on :success do |event|
                mock.call(event.task)
            end
            trsc.replace(p1, p2)
        end
        mock.should_receive(:call).with(t2).once
        execute do
            t1.start!
            t1.success!
            t2.start!
            t2.success!
        end
    end

    def test_commits_plan_services_finalization_handlers
        root, t1, t2 = prepare_plan add: 3, model: Tasks::Simple
        root.depends_on t1, model: Tasks::Simple
        root.depends_on t2, model: Tasks::Simple
        service = Roby::PlanService.get(t1)

        FlexMock.use do |mock|
            transaction_commit(plan, t1, t2) do |trsc, p1, p2|
                service_proxy = trsc.find_plan_service(p1)
                service_proxy.when_finalized do
                    mock.call
                end
                trsc.replace(p1, p2)
            end
            mock.should_receive(:call).once
            execute do
                plan.remove_task(t2)
            end
        end
    end

    def test_commit_keeps_and_generators_functioning
        t1, (t2, t3) = prepare_plan add: 1, tasks: 2, model: Tasks::Simple
        transaction_commit(plan, t1) do |trsc, p1|
            trsc.add_mission_task(t2)
            trsc.add_mission_task(t3)
            and_generator = (p1.start_event & t2.start_event)
            and_generator.signals t3.start_event
        end

        execute { t1.start! }
        assert(!t3.running?)
        execute { t2.start! }
        assert(t3.running?)
    end

    def test_commit_fails_if_it_creates_a_cycle_in_a_dag
        t1, t2, t3 = prepare_plan add: 3
        t1.depends_on t2
        t2.depends_on t3
        copy, mappings = plan.deep_copy
        assert_raises(Relations::CycleFoundError) do
            transaction_commit(plan, t1, t3) do |trsc, p1, p3|
                p3.depends_on p1
            end
        end
        assert plan.same_plan?(copy, mappings)
    end

    def test_or_event_aggregator
        t1, (t2, t3) = prepare_plan add: 1, tasks: 2, model: Tasks::Simple
        transaction_commit(plan, t1) do |trsc, p1|
            trsc.add_mission_task(t2)
            trsc.add_mission_task(t3)
            (p1.event(:start) | t2.event(:start)).signals t3.event(:start)
        end

        execute { t1.start! }
        assert(t3.running?)
        execute { t2.start! }
    end

    def test_commit_execute_handlers
        model = Roby::Task.new_submodel
        plan.add(t = model.new)

        expected = []
        t.execute { |task| }
        expected << t.execute_handlers[0]

        transaction_commit(plan, t) do |trsc, p|
            p.execute { |_| }
            assert_equal expected, t.execute_handlers
            expected << p.execute_handlers[0]
        end

        assert_equal expected, t.execute_handlers
    end

    def test_commit_poll_handlers
        model = Roby::Task.new_submodel
        plan.add(t = model.new)

        expected = []
        t.poll { |task| }
        expected << t.poll_handlers[0]

        transaction_commit(plan, t) do |trsc, p|
            p.poll { |_| }
            assert_equal expected, t.poll_handlers
            expected << p.poll_handlers[0]
        end

        assert_equal expected, t.poll_handlers
    end

    def test_commit_event_handlers
        model = Class.new(Roby::EventGenerator) do
            def called_by_handler(mock)
                mock.called_by_handler
            end
        end

        plan.add(e = model.new(true))

        FlexMock.use do |mock|
            e.on { |ev| mock.old_handler_called }
            transaction_commit(plan, e) do |trsc, pe|
                pe.on { |ev| mock.new_handler_called }
                pe.on { |ev| pe.called_by_handler(mock) }
            end

            mock.should_receive(:old_handler_called).once
            mock.should_receive(:new_handler_called).once
            mock.should_receive(:called_by_handler).once
            execute { e.call(nil) }
        end
    end

    def test_proxy_forwarder_behaviour
        t1, (t2, t3) = prepare_plan add: 1, tasks: 2

        ev = nil
        transaction_commit(plan, t1) do |trsc, p1|
            ev = EventGenerator.new do
                p1.start_event.forward_to t2.start_event
                p1.start_event.signals t3.start_event
            end
            trsc.add(ev)
            ev
        end
        execute { ev.call }
        assert(t1.event(:start).child_object?(t2.event(:start), Roby::EventStructure::Forwarding))
        assert(t1.event(:start).child_object?(t3.event(:start), Roby::EventStructure::Signal))
    end

    def test_state_index
        t1, t2, t3 = (1..3).map { Tasks::Simple.new }

        plan.add(t1)
        plan.add(t2)
        plan.add(t3)
        execute do
            t2.start!
            t3.start!
            t3.stop!
        end
        transaction_commit(plan, t1, t2, t3) do |trsc, p1, p2, p3|
            assert(trsc.task_index.by_predicate[:pending?].include?(p1))
            assert(trsc.task_index.by_predicate[:running?].include?(p2))
            assert(trsc.task_index.by_predicate[:finished?].include?(p3))
        end
    end

    def test_when_unreachable_is_propagated_to_the_plan
        t1 = prepare_plan add: 1, model: Tasks::Simple
        mock = flexmock
        mock.should_receive(:is_unreachable).once
        transaction_commit(plan, t1) do |trsc, p1|
            p1.stop_event.when_unreachable do |*_|
                mock.is_unreachable
            end
        end
        execute { plan.remove_task(t1) }
    end

    def test_it_emits_add_relation_hooks_for_tasks
        plan.add(plan_parent = Roby::Task.new)
        plan.add(plan_child = Roby::Task.new)
        trsc_parent = Roby::Task.new
        trsc_child  = Roby::Task.new
        transaction_commit(plan, plan_parent, plan_child) do |trsc, p_plan_parent, p_plan_child|
            flexmock(trsc).should_receive(:commit_transaction).once.ordered.pass_thru
            flexmock(plan_parent) do |r|
                r.should_receive(:adding_child).with(trsc_child, any).once.ordered(:adding)
                r.should_receive(:added_child).with(trsc_child, any).once.ordered(:added)
                r.should_receive(:adding_child).with(plan_child, any).once.ordered(:adding)
                r.should_receive(:added_child).with(plan_child, any).once.ordered(:added)
            end
            flexmock(trsc_parent) do |r|
                r.should_receive(:adding_child).with(trsc_child, any).once.ordered(:adding)
                r.should_receive(:added_child).with(trsc_child, any).once.ordered(:added)
                r.should_receive(:adding_child).with(plan_child, any).once.ordered(:adding)
                r.should_receive(:added_child).with(plan_child, any).once.ordered(:added)
            end
            p_plan_parent.depends_on trsc_child
            p_plan_parent.depends_on p_plan_child
            trsc_parent.depends_on trsc_child
            trsc_parent.depends_on p_plan_child
        end
    end

    def test_it_emits_remove_relation_hooks_for_tasks
        plan.add(plan_parent = Roby::Task.new)
        plan_child = plan_parent.depends_on(Roby::Task.new)
        transaction_commit(plan, plan_parent, plan_child) do |trsc, p_plan_parent, p_plan_child|
            flexmock(trsc).should_receive(:commit_transaction).once.ordered.pass_thru
            flexmock(plan_parent) do |r|
                r.should_receive(:removing_child).with(plan_child, any).once.ordered(:adding)
                r.should_receive(:removed_child).with(plan_child, any).once.ordered(:added)
            end
            p_plan_parent.remove_child p_plan_child
        end
    end

    def test_it_emits_add_relation_hooks_for_events
        plan.add(plan_parent = Roby::EventGenerator.new)
        plan.add(plan_child = Roby::EventGenerator.new)
        trsc_parent = Roby::EventGenerator.new
        trsc_child  = Roby::EventGenerator.new
        transaction_commit(plan, plan_parent, plan_child) do |trsc, p_plan_parent, p_plan_child|
            flexmock(trsc).should_receive(:commit_transaction).once.ordered.pass_thru
            flexmock(plan_parent) do |r|
                r.should_receive(:adding_forwarding).with(trsc_child, any).once
                r.should_receive(:added_forwarding).with(trsc_child, any).once
                r.should_receive(:adding_forwarding).with(plan_child, any).once
                r.should_receive(:added_forwarding).with(plan_child, any).once
            end
            flexmock(trsc_parent) do |r|
                r.should_receive(:adding_forwarding).with(trsc_child, any).once
                r.should_receive(:added_forwarding).with(trsc_child, any).once
                r.should_receive(:adding_forwarding).with(plan_child, any).once
                r.should_receive(:added_forwarding).with(plan_child, any).once
            end
            p_plan_parent.forward_to trsc_child
            p_plan_parent.forward_to p_plan_child
            trsc_parent.forward_to trsc_child
            trsc_parent.forward_to p_plan_child
        end
    end

    def test_it_emits_remove_relation_hooks_for_events
        plan.add(plan_parent = Roby::EventGenerator.new)
        plan_parent.forward_to(plan_child = Roby::EventGenerator.new)
        transaction_commit(plan, plan_parent, plan_child) do |trsc, p_plan_parent, p_plan_child|
            flexmock(trsc).should_receive(:commit_transaction).once.ordered.pass_thru
            flexmock(plan_parent) do |r|
                r.should_receive(:removing_forwarding).with(plan_child, any).once
                r.should_receive(:removed_forwarding).with(plan_child, any).once
            end
            p_plan_parent.remove_forwarding p_plan_child
        end
    end
end

class TC_RecursiveTransaction < Minitest::Test
    include TC_TransactionBehaviour

    attr_reader :real_plan
    def engine
        (real_plan || plan).engine
    end

    def setup
        super
        @real_plan = @plan
        @plan = Roby::Transaction.new(real_plan)
    end

    def teardown
        plan.discard_transaction
        real_plan.clear
        @plan = real_plan
        super
    end

    def test_real_plan
        transaction_commit(plan) do |trsc|
            assert_equal(real_plan, trsc.real_plan)
        end
    end

    def test_transaction_stack
        transaction_commit(plan) do |trsc|
            assert_equal([trsc, plan, real_plan], trsc.transaction_stack)
        end
    end
end

module Roby
    describe Transaction do
        before do
            @plan = Plan.new
            @transaction = Transaction.new(@plan)
        end

        describe "first level transaction" do
            it "is not root" do
                refute @transaction.root_plan?
            end

            it "includes itself and the plan in the stack" do
                assert_equal [@transaction, @plan], @transaction.transaction_stack
            end

            describe "replace plan tasks within a transaction" do
                describe "#replace" do
                    before do
                        plan.add(@task = Roby::Task.new)
                        plan.add(@replaced_task = Roby::Task.new)
                        plan.add(@replacing_task = Roby::Task.new)
                    end

                    PlanReplaceBehaviors.in_transaction_context(self, :replace)
                    PlanReplaceBehaviors.replace(self)

                    it "does not wrap events that are not needed" do
                        @replacing_task.depends_on(intermediate = Roby::Task.new)
                        intermediate.depends_on(other = Roby::Task.new)
                        @replaced_task.start_event.forward_to other.start_event
                        other.stop_event.forward_to @replaced_task.stop_event
                        replaced_proxy = @transaction[@replaced_task]
                        replacing_proxy = @transaction[@replacing_task]
                        # transactions do wrap task events if they are involved
                        # in relations with other task's events. Moreover, a
                        # replacing task event is instanciated in order to call
                        # #initialize_replacement, so we get both start and
                        # stop on both sides
                        @transaction.replace(replaced_proxy, replacing_proxy)
                        assert_equal %i[start stop], replaced_proxy.each_event.map(&:symbol)
                        assert_equal %i[start stop], replacing_proxy.each_event.map(&:symbol)
                    end

                    it "does not wrap events that are not needed" do
                        @replaced_task.start_event.forward_to @replacing_task.start_event
                        @replacing_task.stop_event.forward_to @replaced_task.stop_event
                        replaced_proxy  = @transaction[@replaced_task]
                        replacing_proxy = @transaction[@replacing_task]
                        @transaction.replace(replaced_proxy, replacing_proxy)
                        assert_equal %i[start stop], replaced_proxy.each_event.map(&:symbol)
                        assert_equal %i[start stop], replacing_proxy.each_event.map(&:symbol)
                    end
                end

                describe "#replace_task" do
                    before do
                        plan.add(@task = Roby::Task.new)
                        plan.add(@replaced_task = Roby::Task.new)
                        plan.add(@replacing_task = Roby::Task.new)
                    end

                    PlanReplaceBehaviors.in_transaction_context(self, :replace_task)
                    PlanReplaceBehaviors.replace_task(self)
                end
            end
        end
    end
end
