# frozen_string_literal: true

require 'roby/test/self'
require 'roby/tasks/simple'

module Roby
    module Queries
        describe TaskMatcher do
            describe 'the _event accessor' do
                attr_reader :task_m
                before do
                    @task_m = Roby::Tasks::Simple.new_submodel do
                        event :extra
                    end
                end

                it 'returns the task event generator matcher for the given event' do
                    matcher = plan.find_tasks(task_m).extra_event
                    assert_equal [task_m], matcher.task_matcher.model
                    assert_equal 'extra', matcher.symbol
                end
                it 'raises ArgumentError if arguments have been given' do
                    e = assert_raises(ArgumentError) do
                        plan.find_tasks(task_m).extra_event(10)
                    end
                    assert_equal 'extra_event expected zero arguments, got 1',
                                 e.message
                end
                it 'raises NoMethodError if the event does not exist '\
                   'in the selected models' do
                    e = assert_raises(NoMethodError) do
                        plan.find_tasks(task_m).does_not_exist_event
                    end
                    assert_equal "no event 'does_not_exist' in match model #{task_m}, "\
                                 'use #which_fullfills to narrow the task model',
                                 e.message
                end
                it 'matches against Roby::Task if no models have been selected at all' do
                    matcher = plan.find_tasks.start_event
                    assert_equal [], matcher.task_matcher.model
                    assert_equal 'start', matcher.symbol
                end
            end
        end
    end
end

class TestQueriesTaskMatcher < Minitest::Test
    TaskMatcher = Queries::TaskMatcher

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

        plan.in_transaction do |trsc|
            check_matches_fullfill(task_model, trsc, trsc[t0], trsc[t1], trsc[t2])
        end
    end

    def test_query_predicates
        t1 = Tasks::Simple.new_submodel { argument :fake }.new
        t2 = Roby::Task.new
        plan.add [t1, t2]

        assert_finds_tasks [], TaskMatcher.executable
        assert_finds_tasks [t1, t2], TaskMatcher.not_executable
        assert_finds_tasks [t2], TaskMatcher.abstract
        assert_finds_tasks [t1], TaskMatcher.partially_instanciated
        assert_finds_tasks [t2], TaskMatcher.fully_instanciated
        t1.arguments[:fake] = 2
        assert_finds_tasks [t1, t2], TaskMatcher.fully_instanciated
        assert_finds_tasks [t2], TaskMatcher.fully_instanciated.abstract

        assert_finds_tasks [t1, t2], TaskMatcher.pending
        execute { t1.start! }
        assert_finds_tasks [t2], TaskMatcher.pending
        assert_finds_tasks [t1, t2], TaskMatcher.not_failed
        assert_finds_tasks [t1, t2], TaskMatcher.not_success
        assert_finds_tasks [t1, t2], TaskMatcher.not_finished

        assert_finds_tasks [t1], TaskMatcher.running
        execute { t1.success! }
        assert_finds_tasks [t1], TaskMatcher.success
        assert_finds_tasks [t1], TaskMatcher.finished
        assert_finds_tasks [t1, t2], TaskMatcher.not_failed
        assert_finds_tasks [t2], TaskMatcher.not_finished

        execute { plan.remove_task(t1) }

        t1 = Tasks::Simple.new
        plan.add(t1)
        execute do
            t1.start!
            t1.failed!
        end
        assert_finds_tasks [t1], TaskMatcher.failed
        assert_finds_tasks [t1], TaskMatcher.finished
        assert_finds_tasks [t1], TaskMatcher.finished.not_success
    end

    def test_it_does_not_allow_specifying_different_constraints_on_the_same_argument
        matcher = Tasks::Simple.match.with_arguments(id: 1)
        assert_raises(ArgumentError) { matcher.with_arguments(id: 2) }
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
