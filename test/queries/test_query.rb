# frozen_string_literal: true

require 'roby/test/self'
require 'roby/tasks/simple'

class TestCaseQueriesQuery < Minitest::Test
    TaskMatcher = Queries::TaskMatcher

    def check_matches_fullfill(task_model, plan, _t0, t1, t2)
        result = plan.find_tasks.which_fullfills(task_model, value: 2).to_set
        assert_equal([t2].to_set, result)
        # Try the shortcut of find_tasks(model, args) for
        # find_tasks.which_fullfills(model, args)
        result = plan.find_tasks(task_model, value: 2).to_set
        assert_equal([t2].to_set, result)
        result = plan.find_tasks(task_model).to_set
        assert_equal([t1, t2].to_set, result)
    end

    def test_match_task_fullfills
        task_model = Task.new_submodel do
            argument :value
        end

        t0 = Roby::Task.new(value: 1)
        t1 = task_model.new(value: 1)
        t2 = task_model.new(value: 2)

        plan.add_mission_task(t0)
        plan.add_mission_task(t1)
        plan.add_mission_task(t2)

        check_matches_fullfill(task_model, plan, t0, t1, t2)
    end

    def test_match_proxy_fullfills
        task_model = Task.new_submodel do
            argument :value
        end

        t0 = Roby::Task.new(value: 1)
        t1 = task_model.new(value: 1)
        t2 = task_model.new(value: 2)

        plan.add_mission_task(t0)
        plan.add_mission_task(t1)
        plan.add_mission_task(t2)

        plan.in_transaction do |trsc|
            check_matches_fullfill(task_model, trsc, trsc[t0], trsc[t1], trsc[t2])
        end
    end

    def test_query_plan_predicates
        t1, t2, t3 = prepare_plan missions: 1, add: 1, tasks: 1
        plan.add_permanent_task(t3)
        assert_sets_equal [t1], plan.find_tasks.mission
        assert_sets_equal [t2, t3], plan.find_tasks.not_mission
        assert_sets_equal [t3], plan.find_tasks.permanent
        assert_sets_equal [t1, t2], plan.find_tasks.not_permanent
    end

    def test_child_match
        plan.add(t1 = Tasks::Simple.new(id: 1))
        t2 = Tasks::Simple.new_submodel.new(id: '2')
        tag = TaskService.new_submodel do
            argument :tag_id
        end
        t3_model = Tasks::Simple.new_submodel
        t3_model.include tag
        t3 = t3_model.new(id: 3, tag_id: 3)
        t1.depends_on t2
        t2.depends_on t3
        t1.depends_on t3

        # t1    Tasks::Simple                   id: 1
        # t2    t2_model < Tasks::Simple        id: '2'
        # t3    t3_model < tag < Tasks::Simple  id: 3
        # t1 -> t2 -> t3
        # t1 -> t3

        assert_equal 3, plan.find_tasks(t1.model).to_a.size

        child_match = TaskMatcher.which_fullfills(Tasks::Simple, id: 1)
        assert_empty plan.find_tasks(t1.model).with_child(child_match)

        assert_sets_equal [t1, t2],
                          plan.find_tasks(Tasks::Simple).with_child(Tasks::Simple)
        assert_sets_equal [t1],
                          plan.find_tasks(Tasks::Simple)
                              .with_child(Tasks::Simple, id: '2')
        assert_sets_equal [t1], plan.find_tasks(Tasks::Simple)
                                    .with_child(t2.model).with_child(t3.model)
        assert_sets_equal [t1, t2], plan.find_tasks(Tasks::Simple).with_child(t3.model)
        assert_sets_equal [t1, t2], plan.find_tasks(Tasks::Simple).with_child(tag, id: 3)
        # :id is not an argument of +tag+, so the following should match, but
        # the next one not.
        assert_sets_equal [t1, t2],
                          plan.find_tasks(Tasks::Simple).with_child(tag, id: 2)
        assert_empty plan.find_tasks(Tasks::Simple).with_child(tag, tag_id: 2)
        assert_empty plan.find_tasks(t1.model)
                         .with_child(Tasks::Simple, TaskStructure::PlannedBy)

        t1.planned_by t2
        assert_sets_equal [t1],
                          plan.find_tasks(t1.model)
                              .with_child(Tasks::Simple, TaskStructure::PlannedBy)
        assert_sets_equal [t1],
                          plan.find_tasks(t1.model)
                              .with_child(Tasks::Simple,
                                          relation: TaskStructure::PlannedBy)
        assert_empty plan.find_tasks(t1.model)
                         .with_child(Tasks::Simple,
                                     id: 42, relation: TaskStructure::PlannedBy)
        assert_empty plan.find_tasks(t1.model)
                         .with_child(Tasks::Simple, TaskStructure::PlannedBy,
                                     an_argument: :which_is_set)
        t1.remove_child_object(t2, TaskStructure::PlannedBy)

        child_match = TaskMatcher.which_fullfills(Tasks::Simple, id: t2.arguments[:id])
        assert_equal [t1].to_set, plan.find_tasks(t1.model).with_child(child_match).to_set
        assert_equal [], plan.find_tasks(t1.model)
                             .with_child(Tasks::Simple, TaskStructure::PlannedBy).to_a
    end

    def test_child_in_transactions
        (t1, t2), t3 = prepare_plan add: 2, tasks: 1, model: Tasks::Simple
        t1.depends_on t2
        plan.in_transaction do |trsc|
            trsc[t2].depends_on t3

            assert_equal 3, trsc.find_tasks(t1.model).to_a.size
            child_match = TaskMatcher.which_fullfills(Tasks::Simple, id: 1)
            assert_empty trsc.find_tasks(t1.model).with_child(child_match)

            child_match = TaskMatcher.which_fullfills(Tasks::Simple)
            assert_sets_equal [trsc[t1], trsc[t2]],
                              trsc.find_tasks(t1.model).with_child(child_match)

            child_match = TaskMatcher.which_fullfills(
                Tasks::Simple, id: t2.arguments[:id]
            )
            assert_equal [trsc[t1]].to_set,
                         trsc.find_tasks(t1.model).with_child(child_match).to_set
        end
    end

    def test_parent_match
        plan.add(t1 = Tasks::Simple.new(id: 1))
        t2 = Tasks::Simple.new_submodel.new(id: 2)
        t3 = Tasks::Simple.new_submodel.new(id: 3)
        t3.depends_on t2
        t3.depends_on t1
        t2.depends_on t1

        assert_equal(3, plan.find_tasks(Tasks::Simple).to_a.size)

        parent_match = TaskMatcher.which_fullfills(Tasks::Simple, id: 1)
        assert_empty plan.find_tasks(Tasks::Simple).with_parent(parent_match)

        assert_sets_equal [t1, t2], plan.find_tasks(Tasks::Simple)
                                        .with_parent(Tasks::Simple)
        assert_sets_equal [t1], plan.find_tasks(Tasks::Simple)
                                    .with_parent(t3.model).with_parent(t2.model)
        assert_empty plan.find_tasks(Tasks::Simple)
                         .with_parent(Tasks::Simple, TaskStructure::PlannedBy)
        t2.planned_by t1
        assert_sets_equal [t1], plan.find_tasks(t1.model)
                                    .with_parent(Tasks::Simple, TaskStructure::PlannedBy)
        assert_sets_equal [t1], plan.find_tasks(t1.model)
                                    .with_parent(
                                        Tasks::Simple, relation: TaskStructure::PlannedBy
                                    )
        assert_empty plan.find_tasks(t1.model)
                         .with_parent(
                             Tasks::Simple,
                             id: 42, relation: TaskStructure::PlannedBy
                         )
        assert_empty plan.find_tasks(t1.model)
                         .with_parent(
                             Tasks::Simple, TaskStructure::PlannedBy,
                             an_argument: :which_is_set
                         )
        t2.remove_child_object(t1, TaskStructure::PlannedBy)

        assert_sets_equal [t1], plan.find_tasks(Tasks::Simple)
                                    .with_parent(
                                        Tasks::Simple, id: t2.arguments[:id]
                                    )
        assert_empty plan.find_tasks(Tasks::Simple)
                         .with_parent(
                             Tasks::Simple,
                             id: t2.arguments[:id],
                             relation: TaskStructure::PlannedBy
                         )
    end

    def test_parent_in_transaction
        (t1, t2), t3 = prepare_plan add: 2, tasks: 1, model: Tasks::Simple
        t1.depends_on t2
        plan.in_transaction do |trsc|
            trsc[t2].depends_on t3

            assert_equal 3, trsc.find_tasks(Tasks::Simple).to_a.size

            parent_match = TaskMatcher.which_fullfills(Tasks::Simple, id: 1)
            assert_empty trsc.find_tasks(Tasks::Simple).with_parent(parent_match)

            parent_match = TaskMatcher.which_fullfills(Tasks::Simple)
            assert_sets_equal [trsc[t2], t3], trsc.find_tasks(Tasks::Simple)
                                                  .with_parent(parent_match)

            parent_match = TaskMatcher.which_fullfills(
                Tasks::Simple, id: t2.arguments[:id]
            )
            assert_sets_equal [t3], trsc.find_tasks(Tasks::Simple)
                                        .with_parent(parent_match)
        end
    end

    def assert_sets_equal(a, b)
        assert_equal a.to_set, b.to_set
    end

    def assert_empty(a)
        assert_equal [], a.to_a
    end
end

module Roby
    module Queries
        describe Query do
            describe '#===' do
                before do
                    @query = plan.find_tasks
                    flexmock(plan)
                end

                it 'does not match if one of the positive predicates returns false' do
                    @query.plan_predicates << :mypred
                    plan.should_receive(:mypred).explicitly.and_return(false).once
                    refute @query === Tasks::Simple.new
                end

                it 'matches if all the positive predicates returns true' do
                    @query.plan_predicates << :mypred
                    plan.should_receive(:mypred).explicitly.and_return(true).once
                    assert @query === Tasks::Simple.new
                end

                it 'matches if one of the negative predicates returns false' do
                    @query.neg_plan_predicates << :mypred
                    plan.should_receive(:mypred).explicitly.and_return(false).once
                    assert @query === Tasks::Simple.new
                end

                it 'does not match if one of the negative predicates returns true' do
                    @query.neg_plan_predicates << :mypred
                    plan.should_receive(:mypred).explicitly.and_return(true).once
                    refute @query === Tasks::Simple.new
                end
            end

            describe 'in transactions with global scope' do
                before do
                    @task_m = Roby::Task.new_submodel do
                        argument :id
                    end
                    @t1, @t2, @t3 = (1..3).map { |i| @task_m.new(id: i) }
                    @t1.depends_on @t2
                    plan.add(@t1)

                    @trsc = Transaction.new(plan)
                end

                after do
                    @trsc.discard_transaction unless @trsc.frozen?
                end

                it 'finds tasks in the transaction' do
                    @trsc.add(@t3)
                    result = @trsc.find_tasks.which_fullfills(@task_m, id: 3).to_a
                    assert_equal [@t3], result
                end

                it 'finds proxies in the transaction' do
                    p1 = @trsc.wrap(@t1)
                    result = @trsc.find_tasks.which_fullfills(@task_m, id: 1).to_a
                    assert_equal [p1], result
                end

                it 'finds tasks from the plan that are not yet in the transaction' do
                    result = @trsc.find_tasks.which_fullfills(@task_m, id: 1).to_a
                    assert_equal [@trsc[@t1]], result
                end

                it 'does not proxy plan tasks not matched by the query' do
                    @trsc.find_tasks.which_fullfills(@task_m, id: 1).to_a
                    refute @trsc.has_task?(@t2)
                    refute @trsc.has_task?(@t3)
                end

                it 'finds tasks after they are added by a transaction' do
                    @trsc.add(@t3)
                    @trsc.commit_transaction
                    result = plan.find_tasks.which_fullfills(@task_m, id: 3).to_a
                    assert_equal([@t3], result)
                end
            end

            describe '#roots' do
                # !!! IMPORTANT
                # In all tests we MUST resolve the query before we check the
                # result since we want to test whether the query creates the
                # proxies

                before do
                    @trsc = Transaction.new(plan)
                end

                it 'returns all single tasks of a plan' do
                    t1, t2, t3 = prepare_plan add: 3
                    assert_equal [t1, t2, t3].to_set,
                                 plan.find_tasks.roots(TaskStructure::Dependency).to_set
                end

                it 'rejects tasks from a single plan that have parents' do
                    t1, t2, t3 = prepare_plan add: 3
                    t1.depends_on t2
                    assert_equal [t1, t3].to_set,
                                 plan.find_tasks.roots(TaskStructure::Dependency).to_set
                end

                it 'handles having a child in the transaction and the parent '\
                   'in the plan for a relation in the plan' do
                    plan.add(parent = Tasks::Simple.new)
                    plan.add(child = Tasks::Simple.new)
                    parent.depends_on child
                    @trsc[child]

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_a
                    assert_equal [@trsc[parent]], query_results
                end

                it 'handles having a parent in the transaction and the child '\
                   'in the plan' do
                    plan.add(parent = Tasks::Simple.new)
                    plan.add(child = Tasks::Simple.new)
                    parent.depends_on child
                    @trsc[parent]

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_a
                    assert_equal [@trsc[parent]], query_results
                end

                it 'handles having a plan task with a new parent in the transaction' do
                    @trsc.add(parent = Tasks::Simple.new)
                    plan.add(child = Tasks::Simple.new)
                    parent.depends_on @trsc[child]

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_a
                    assert_equal [parent], query_results
                end

                it 'handles having a plan task with a new child in the transaction' do
                    plan.add(parent = Tasks::Simple.new)
                    @trsc.add(child = Tasks::Simple.new)
                    @trsc[parent].depends_on child

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_a
                    assert_equal [@trsc[parent]], query_results
                end

                it 'handles having a plan relation removed by the transaction' do
                    plan.add(parent = Tasks::Simple.new)
                    plan.add(child = Tasks::Simple.new)
                    parent.depends_on child
                    @trsc[parent].remove_child @trsc[child]

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_set
                    assert_equal [@trsc[parent], @trsc[child]].to_set, query_results
                end

                it 'considers objects in all levels of the plan' do
                    t1, t2, t3 = prepare_plan add: 3
                    tr1, tr2, tr3 = prepare_plan tasks: 3
                    [tr1, tr2, tr3].each { |t| @trsc.add(t) }

                    t1.depends_on t2
                    tr1.depends_on tr2
                    @trsc[t3].depends_on tr3
                    refute @trsc.find_local_object_for_task(t2)

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_set
                    assert_equal [@trsc[t1], @trsc[t3], tr1].to_set, query_results
                end

                it 'considers the merged graph' do
                    t1, t2 = prepare_plan add: 2
                    @trsc.add(tr = Roby::Tasks::Simple.new)

                    t1.depends_on t2
                    @trsc[t2].depends_on tr

                    # !!! IMPORTANT
                    # We MUST resolve the query before we check the result
                    # since we want to test whether the query creates the
                    # proxies
                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_set
                    assert_equal [@trsc[t1]].to_set, query_results
                end
            end
        end
    end
end
