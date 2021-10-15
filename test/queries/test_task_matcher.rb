# frozen_string_literal: true

require "roby/test/self"
require "roby/tasks/simple"

module Roby
    module Queries
        describe TaskMatcher do
            describe "plan enumeration of basic predicates" do
                after do
                    plan.each_task do |t|
                        execute { t.start_event.emit } if t.starting?
                        execute { t.stop_event.emit } if t.finishing?
                    end
                end

                it "matches on #executable?" do
                    plan.add(yes = Tasks::Simple.new)
                    plan.add(no = Tasks::Simple.new)
                    no.executable = false

                    assert_finds_tasks [yes], TaskMatcher.executable
                    assert_finds_tasks [no], TaskMatcher.not_executable
                end

                it "matches on #abstract?" do
                    plan.add(yes = Tasks::Simple.new)
                    plan.add(no = Tasks::Simple.new)
                    yes.abstract = true

                    assert_finds_tasks [yes], TaskMatcher.abstract
                    assert_finds_tasks [no], TaskMatcher.not_abstract
                end

                it "matches on #fully_instanciated?" do
                    task_m = Roby::Task.new_submodel { argument :arg }
                    plan.add(yes = task_m.new(arg: 10))
                    plan.add(no = task_m.new)
                    assert_finds_tasks [yes], TaskMatcher.fully_instanciated
                    assert_finds_tasks [no], TaskMatcher.not_fully_instanciated
                end

                it "matches on #partially_instanciated?" do
                    task_m = Roby::Task.new_submodel { argument :arg }
                    plan.add(no = task_m.new(arg: 10))
                    plan.add(yes = task_m.new)
                    assert_finds_tasks [yes], TaskMatcher.partially_instanciated
                    assert_finds_tasks [no], TaskMatcher.not_partially_instanciated
                end

                it "deals with dynamic argument assignation" do
                    task_m = Roby::Task.new_submodel { argument :arg }
                    plan.add(t1 = task_m.new)
                    plan.add(t2 = task_m.new(arg: 10))
                    assert_finds_tasks [t1], TaskMatcher.partially_instanciated
                    assert_finds_tasks [t1], TaskMatcher.not_fully_instanciated
                    assert_finds_tasks [t2], TaskMatcher.fully_instanciated
                    assert_finds_tasks [t2], TaskMatcher.not_partially_instanciated
                    t1.arg = 10
                    assert_finds_tasks [], TaskMatcher.partially_instanciated
                    assert_finds_tasks [], TaskMatcher.not_fully_instanciated
                    assert_finds_tasks [t1, t2], TaskMatcher.fully_instanciated
                    assert_finds_tasks [t1, t2], TaskMatcher.not_partially_instanciated
                end

                it "matches pending tasks" do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [t], TaskMatcher.pending
                    assert_finds_tasks [], TaskMatcher.not_pending
                    execute { t.start! }
                    assert_finds_tasks [], TaskMatcher.pending
                    assert_finds_tasks [t], TaskMatcher.not_pending
                end

                it "matches starting tasks" do
                    task_m = Roby::Tasks::Simple.new_submodel do
                        event(:start) { |_| }
                    end
                    plan.add(t = task_m.new)
                    assert_finds_tasks [t], TaskMatcher.not_starting
                    assert_finds_tasks [], TaskMatcher.starting
                    execute { t.start! }
                    assert_finds_tasks [], TaskMatcher.not_starting
                    assert_finds_tasks [t], TaskMatcher.starting
                    execute { t.start_event.emit }
                    assert_finds_tasks [t], TaskMatcher.not_starting
                    assert_finds_tasks [], TaskMatcher.starting
                end

                it "matches running tasks" do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [], TaskMatcher.running
                    assert_finds_tasks [t], TaskMatcher.not_running
                    execute { t.start! }
                    assert_finds_tasks [t], TaskMatcher.running
                    assert_finds_tasks [], TaskMatcher.not_running
                    execute { t.stop_event.emit }
                    assert_finds_tasks [], TaskMatcher.running
                    assert_finds_tasks [t], TaskMatcher.not_running
                end

                it "matches finishing tasks" do
                    task_m = Roby::Tasks::Simple.new_submodel do
                        event(:stop) { |_| }
                    end
                    plan.add(t = task_m.new)
                    execute { t.start! }
                    assert_finds_tasks [t], TaskMatcher.not_finishing
                    assert_finds_tasks [], TaskMatcher.finishing
                    execute { t.stop! }
                    assert_finds_tasks [], TaskMatcher.not_finishing
                    assert_finds_tasks [t], TaskMatcher.finishing
                    execute { t.stop_event.emit }
                    assert_finds_tasks [t], TaskMatcher.not_finishing
                    assert_finds_tasks [], TaskMatcher.finishing
                end

                it "matches successful tasks" do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [t], TaskMatcher.not_success
                    assert_finds_tasks [], TaskMatcher.success
                    execute { t.start! }
                    assert_finds_tasks [t], TaskMatcher.not_success
                    assert_finds_tasks [], TaskMatcher.success
                    execute { t.success_event.emit }
                    assert_finds_tasks [], TaskMatcher.not_success
                    assert_finds_tasks [t], TaskMatcher.success
                    assert_finds_tasks [t], TaskMatcher.finished
                    assert_finds_tasks [t], TaskMatcher.not_failed
                end

                it "matches failed tasks" do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [t], TaskMatcher.not_failed
                    assert_finds_tasks [], TaskMatcher.failed
                    execute { t.start! }
                    assert_finds_tasks [t], TaskMatcher.not_failed
                    assert_finds_tasks [], TaskMatcher.failed
                    execute { t.failed_event.emit }
                    assert_finds_tasks [], TaskMatcher.not_failed
                    assert_finds_tasks [t], TaskMatcher.failed
                    assert_finds_tasks [t], TaskMatcher.finished
                    assert_finds_tasks [t], TaskMatcher.not_success
                end

                it "matches finished tasks" do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [t], TaskMatcher.not_finished
                    assert_finds_tasks [], TaskMatcher.finished
                    execute { t.start! }
                    assert_finds_tasks [t], TaskMatcher.not_finished
                    assert_finds_tasks [], TaskMatcher.finished
                    execute { t.stop_event.emit }
                    assert_finds_tasks [], TaskMatcher.not_finished
                    assert_finds_tasks [t], TaskMatcher.finished
                    assert_finds_tasks [t], TaskMatcher.not_failed
                    assert_finds_tasks [t], TaskMatcher.not_success
                end

                it "matches reusable tasks set explicitly" do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [t], TaskMatcher.reusable
                    assert_finds_tasks [], TaskMatcher.not_reusable
                    t.do_not_reuse
                    assert_finds_tasks [], TaskMatcher.reusable
                    assert_finds_tasks [t], TaskMatcher.not_reusable
                end

                it "matches tasks that are not reusable because they are finished" do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [t], TaskMatcher.reusable
                    assert_finds_tasks [], TaskMatcher.not_reusable
                    execute do
                        t.start!
                        t.stop!
                    end
                    assert_finds_tasks [], TaskMatcher.reusable
                    assert_finds_tasks [t], TaskMatcher.not_reusable
                end

                it "matches missions" do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [], TaskMatcher.mission
                    plan.add_mission_task(t)
                    assert_finds_tasks [t], TaskMatcher.mission
                    plan.unmark_mission_task(t)
                    assert_finds_tasks [], TaskMatcher.mission
                end

                it "matches permanent tasks" do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [], TaskMatcher.permanent
                    plan.add_permanent_task(t)
                    assert_finds_tasks [t], TaskMatcher.permanent
                    plan.unmark_permanent_task(t)
                    assert_finds_tasks [], TaskMatcher.permanent
                end
            end

            describe "the _event accessor" do
                attr_reader :task_m

                before do
                    @task_m = Roby::Tasks::Simple.new_submodel do
                        event :extra
                    end
                end

                it "returns the task event generator matcher for the given event" do
                    matcher = task_m.match.extra_event
                    assert_equal [task_m], matcher.task_matcher.model
                    assert_equal "extra", matcher.symbol
                end
                it "raises ArgumentError if arguments have been given" do
                    e = assert_raises(ArgumentError) do
                        task_m.match.extra_event(10)
                    end
                    assert_equal "extra_event expected zero arguments, got 1",
                                 e.message
                end
                it "raises NoMethodError if the event does not exist "\
                   "in the selected models" do
                    e = assert_raises(NoMethodError) do
                        task_m.match.does_not_exist_event
                    end
                    assert_equal "no event 'does_not_exist' in match model #{task_m}, "\
                                 "use #which_fullfills to narrow the task model",
                                 e.message
                end
                it "matches against Roby::Task if no models have been selected at all" do
                    matcher = TaskMatcher.new.start_event
                    assert_equal [], matcher.task_matcher.model
                    assert_equal "start", matcher.symbol
                end
            end

            def assert_match(m, obj)
                assert m === obj
            end

            def refute_match(m, obj)
                refute m === obj
            end

            def assert_finds_tasks(task_set, matcher)
                found_tasks = matcher.each_in_plan(plan).to_set
                assert_equal task_set.to_set, found_tasks
            end
        end
    end
end

class TestQueriesTaskMatcher < Minitest::Test
    TaskMatcher = Queries::TaskMatcher

    def setup
        super
        @plan_stack = [plan]
    end

    def check_matches_fullfill(task_model, plan, t0, t1, t2)
        result = TaskMatcher.new.each_in_plan(plan).to_set
        assert_equal([t1, t2, t0].to_set, result)
        result = TaskMatcher.new.with_model(Roby::Task).each_in_plan(plan).to_set
        assert_equal([t1, t2, t0].to_set, result, plan.task_index.by_model)

        result = TaskMatcher.which_fullfills(task_model).each_in_plan(plan).to_set
        assert_equal([t1, t2].to_set, result)

        result = TaskMatcher.with_model(task_model).each_in_plan(plan).to_set
        assert_equal([t1, t2].to_set, result)
        result = TaskMatcher.with_arguments(value: 1).each_in_plan(plan).to_set
        assert_equal([t0, t1].to_set, result)

        result = TaskMatcher.which_fullfills(task_model, value: 1)
                            .each_in_plan(plan).to_set
        assert_equal([t1].to_set, result)
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

    def test_match_tag
        tag = TaskService.new_submodel
        tag.argument :id
        task_model = Tasks::Simple.new_submodel
        task_model.provides tag

        plan.add(task = task_model.new(id: 3))
        assert_match Task.match(tag), task
        assert_match Task.match(tag, id: 3), task
        refute_match Task.match(tag, id: 2), task

        plan.add(task = Tasks::Simple.new)
        refute_match Task.match(tag), task
        refute_match Task.match(tag, id: 3), task
        refute_match Task.match(tag, id: 2), task
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

        in_transaction do |trsc|
            check_matches_fullfill(task_model, trsc, trsc[t0], trsc[t1], trsc[t2])
        end
    end

    def test_it_does_not_allow_specifying_different_constraints_on_the_same_argument
        matcher = Tasks::Simple.match.with_arguments(id: 1)
        assert_raises(ArgumentError) { matcher.with_arguments(id: 2) }
    end

    def test_child_match
        plan.add(t1 = Tasks::Simple.new(id: 1))
        t2 = Tasks::Simple.new_submodel.new(id: "2")
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

        assert_equal 3, t1.model.match.each_in_plan(plan).to_a.size

        child_match = TaskMatcher.which_fullfills(Tasks::Simple, id: 1)
        assert_finds_nothing t1.model.match.with_child(child_match)

        assert_finds_tasks [t1, t2], Tasks::Simple.match.with_child(Tasks::Simple)
        assert_finds_tasks [t1], Tasks::Simple.match.with_child(Tasks::Simple, id: "2")
        assert_finds_tasks [t1], Tasks::Simple.match.with_child(t2.model)
                                              .with_child(t3.model)
        assert_finds_tasks [t1, t2], Tasks::Simple.match.with_child(t3.model)
        assert_finds_tasks [t1, t2], Tasks::Simple.match.with_child(tag, id: 3)
        # :id is not an argument of +tag+, so the following should match, but
        # the next one not.
        assert_finds_tasks [t1, t2],
                           Tasks::Simple.match.with_child(tag, id: 2)
        assert_finds_nothing Tasks::Simple.match.with_child(tag, tag_id: 2)
        assert_finds_nothing t1.model.match
                               .with_child(Tasks::Simple, TaskStructure::PlannedBy)

        t1.planned_by t2
        assert_finds_tasks [t1], t1.model.match
                                   .with_child(Tasks::Simple, TaskStructure::PlannedBy)
        assert_finds_tasks [t1], t1.model.match
                                   .with_child(Tasks::Simple,
                                               relation: TaskStructure::PlannedBy)
        assert_finds_nothing t1.model.match
                               .with_child(Tasks::Simple,
                                           id: 42, relation: TaskStructure::PlannedBy)
        assert_finds_nothing t1.model.match
                               .with_child(Tasks::Simple, TaskStructure::PlannedBy,
                                           an_argument: :which_is_set)
        t1.remove_child_object(t2, TaskStructure::PlannedBy)

        child_match = TaskMatcher.which_fullfills(Tasks::Simple, id: t2.arguments[:id])
        assert_finds_tasks [t1], t1.model.match.with_child(child_match)
        assert_finds_nothing t1.model.match
                               .with_child(Tasks::Simple, TaskStructure::PlannedBy)
    end

    def test_child_in_transactions
        (t1, t2), t3 = prepare_plan add: 2, tasks: 1, model: Tasks::Simple
        t1.depends_on t2
        in_transaction do |trsc|
            trsc[t2].depends_on t3

            assert_equal 3, t1.model.match.to_a(trsc).size
            child_match = TaskMatcher.which_fullfills(Tasks::Simple, id: 1)
            assert_finds_nothing t1.model.match.with_child(child_match)

            child_match = TaskMatcher.which_fullfills(Tasks::Simple)
            assert_finds_tasks [trsc[t1], trsc[t2]],
                               t1.model.match.with_child(child_match)

            child_match = TaskMatcher.which_fullfills(
                Tasks::Simple, id: t2.arguments[:id]
            )
            assert_finds_tasks [trsc[t1]], t1.model.match.with_child(child_match)
        end
    end

    def test_parent_match
        plan.add(t1 = Tasks::Simple.new(id: 1))
        t2 = Tasks::Simple.new_submodel.new(id: 2)
        t3 = Tasks::Simple.new_submodel.new(id: 3)
        t3.depends_on t2
        t3.depends_on t1
        t2.depends_on t1

        assert_equal 3, Tasks::Simple.match.to_a(plan).size

        parent_match = TaskMatcher.which_fullfills(Tasks::Simple, id: 1)
        assert_finds_nothing Tasks::Simple.match.with_parent(parent_match)

        assert_finds_tasks [t1, t2], Tasks::Simple.match.with_parent(Tasks::Simple)
        assert_finds_tasks [t1], Tasks::Simple.match
                                              .with_parent(t3.model)
                                              .with_parent(t2.model)
        assert_finds_nothing Tasks::Simple.match.with_parent(Tasks::Simple,
                                                             TaskStructure::PlannedBy)

        t2.planned_by t1
        assert_finds_tasks [t1], t1.model.match.with_parent(Tasks::Simple,
                                                            TaskStructure::PlannedBy)
        assert_finds_tasks [t1], t1.model.match
                                   .with_parent(Tasks::Simple,
                                                relation: TaskStructure::PlannedBy)
        assert_finds_nothing(
            t1.model.match
              .with_parent(Tasks::Simple, id: 42, relation: TaskStructure::PlannedBy)
        )

        assert_finds_nothing(
            t1.model.match.with_parent(Tasks::Simple, TaskStructure::PlannedBy,
                                       an_argument: :which_is_set)
        )

        t2.remove_child_object(t1, TaskStructure::PlannedBy)

        assert_finds_tasks [t1], Tasks::Simple.match.with_parent(Tasks::Simple,
                                                                 id: t2.arguments[:id])
        assert_finds_nothing(
            Tasks::Simple.match.with_parent(Tasks::Simple,
                                            id: t2.arguments[:id],
                                            relation: TaskStructure::PlannedBy)
        )
    end

    def test_parent_in_transaction
        (t1, t2), t3 = prepare_plan add: 2, tasks: 1, model: Tasks::Simple
        t1.depends_on t2
        in_transaction do |trsc|
            trsc[t2].depends_on t3

            assert_equal 3, Tasks::Simple.match.to_a(trsc).size

            parent_match = TaskMatcher.which_fullfills(Tasks::Simple, id: 1)
            assert_finds_nothing Tasks::Simple.match.with_parent(parent_match)

            parent_match = TaskMatcher.which_fullfills(Tasks::Simple)
            assert_finds_tasks [trsc[t2], t3], Tasks::Simple.match
                                                            .with_parent(parent_match)

            parent_match = TaskMatcher.which_fullfills(
                Tasks::Simple, id: t2.arguments[:id]
            )
            assert_finds_tasks [t3], Tasks::Simple.match.with_parent(parent_match)
        end
    end

    def assert_match(m, obj)
        assert m === obj
    end

    def refute_match(m, obj)
        refute m === obj
    end

    def in_transaction
        downmost_plan.in_transaction do |trsc|
            begin
                @plan_stack.push(trsc)
                yield(trsc)
            ensure
                @plan_stack.pop
            end
        end
    end

    def downmost_plan
        @plan_stack.last
    end

    def assert_finds_tasks(task_set, matcher)
        found_tasks = matcher.each_in_plan(downmost_plan).to_set
        assert_equal task_set.to_set, found_tasks
    end

    def assert_finds_nothing(matcher)
        assert_finds_tasks([], matcher)
    end
end

module Roby
    module Queries
        describe Query do
            describe "#===" do
                before do
                    @query = plan.find_tasks
                    flexmock(plan)
                    plan.add(@task = Tasks::Simple.new)
                end

                it "does not match if one of the positive predicates returns false" do
                    @query.add_plan_predicate :mission_task?
                    plan.should_receive(:mission_task?).explicitly.and_return(false).once
                    refute @query === @task
                end

                it "matches if all the positive predicates returns true" do
                    @query.add_plan_predicate :mission_task?
                    plan.should_receive(:mission_task?).explicitly.and_return(true).once
                    assert @query === @task
                end

                it "matches if one of the negative predicates returns false" do
                    @query.add_neg_plan_predicate :mission_task?
                    plan.should_receive(:mission_task?).explicitly.and_return(false).once
                    assert @query === @task
                end

                it "does not match if one of the negative predicates returns true" do
                    @query.add_neg_plan_predicate :mission_task?
                    plan.should_receive(:mission_task?).explicitly.and_return(true).once
                    refute @query === @task
                end
            end

            describe "in transactions with global scope" do
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

                it "finds tasks in the transaction" do
                    @trsc.add(@t3)
                    result = @trsc.find_tasks.which_fullfills(@task_m, id: 3).to_a
                    assert_equal [@t3], result
                end

                it "finds proxies in the transaction" do
                    p1 = @trsc.wrap(@t1)
                    result = @trsc.find_tasks.which_fullfills(@task_m, id: 1).to_a
                    assert_equal [p1], result
                end

                it "finds tasks from the plan that are not yet in the transaction" do
                    result = @trsc.find_tasks.which_fullfills(@task_m, id: 1).to_a
                    assert_equal [@trsc[@t1]], result
                end

                it "does not proxy plan tasks not matched by the query" do
                    @trsc.find_tasks.which_fullfills(@task_m, id: 1).to_a
                    refute @trsc.has_task?(@t2)
                    refute @trsc.has_task?(@t3)
                end

                it "finds tasks after they are added by a transaction" do
                    @trsc.add(@t3)
                    @trsc.commit_transaction
                    result = plan.find_tasks.which_fullfills(@task_m, id: 3).to_a
                    assert_equal([@t3], result)
                end
            end

            describe "#roots" do
                # !!! IMPORTANT
                # In all tests we MUST resolve the query before we check the
                # result since we want to test whether the query creates the
                # proxies

                before do
                    @trsc = Transaction.new(plan)
                end

                it "returns all single tasks of a plan" do
                    t1, t2, t3 = prepare_plan add: 3
                    assert_equal [t1, t2, t3].to_set,
                                 plan.find_tasks.roots(TaskStructure::Dependency).to_set
                end

                it "rejects tasks from a single plan that have parents" do
                    t1, t2, t3 = prepare_plan add: 3
                    t1.depends_on t2
                    assert_equal [t1, t3].to_set,
                                 plan.find_tasks.roots(TaskStructure::Dependency).to_set
                end

                it "handles having a child in the transaction and the parent "\
                   "in the plan for a relation in the plan" do
                    plan.add(parent = Tasks::Simple.new)
                    plan.add(child = Tasks::Simple.new)
                    parent.depends_on child
                    @trsc[child]

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_a
                    assert_equal [@trsc[parent]], query_results
                end

                it "handles having a parent in the transaction and the child "\
                   "in the plan" do
                    plan.add(parent = Tasks::Simple.new)
                    plan.add(child = Tasks::Simple.new)
                    parent.depends_on child
                    @trsc[parent]

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_a
                    assert_equal [@trsc[parent]], query_results
                end

                it "handles having a plan task with a new parent in the transaction" do
                    @trsc.add(parent = Tasks::Simple.new)
                    plan.add(child = Tasks::Simple.new)
                    parent.depends_on @trsc[child]

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_a
                    assert_equal [parent], query_results
                end

                it "handles having a plan task with a new child in the transaction" do
                    plan.add(parent = Tasks::Simple.new)
                    @trsc.add(child = Tasks::Simple.new)
                    @trsc[parent].depends_on child

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_a
                    assert_equal [@trsc[parent]], query_results
                end

                it "handles having a plan relation removed by the transaction" do
                    plan.add(parent = Tasks::Simple.new)
                    plan.add(child = Tasks::Simple.new)
                    parent.depends_on child
                    @trsc[parent].remove_child @trsc[child]

                    query_results =
                        @trsc.find_tasks.roots(TaskStructure::Dependency).to_set
                    assert_equal [@trsc[parent], @trsc[child]].to_set, query_results
                end

                it "considers objects in all levels of the plan" do
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

                it "considers the merged graph" do
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
