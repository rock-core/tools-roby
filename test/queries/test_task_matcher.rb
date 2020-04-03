# frozen_string_literal: true

require 'roby/test/self'
require 'roby/tasks/simple'

module Roby
    module Queries
        describe TaskMatcher do
            describe 'plan enumeration of basic predicates' do
                after do
                    plan.each_task do |t|
                        execute { t.start_event.emit } if t.starting?
                        execute { t.stop_event.emit } if t.finishing?
                    end
                end

                it 'matches on #executable?' do
                    plan.add(yes = Tasks::Simple.new)
                    plan.add(no = Tasks::Simple.new)
                    no.executable = false

                    assert_finds_tasks [yes], TaskMatcher.executable
                    assert_finds_tasks [no], TaskMatcher.not_executable
                end

                it 'matches on #abstract?' do
                    plan.add(yes = Tasks::Simple.new)
                    plan.add(no = Tasks::Simple.new)
                    yes.abstract = true

                    assert_finds_tasks [yes], TaskMatcher.abstract
                    assert_finds_tasks [no], TaskMatcher.not_abstract
                end

                it 'matches on #fully_instanciated?' do
                    task_m = Roby::Task.new_submodel { argument :arg }
                    plan.add(yes = task_m.new(arg: 10))
                    plan.add(no = task_m.new)
                    assert_finds_tasks [yes], TaskMatcher.fully_instanciated
                    assert_finds_tasks [no], TaskMatcher.not_fully_instanciated
                end

                it 'matches on #partially_instanciated?' do
                    task_m = Roby::Task.new_submodel { argument :arg }
                    plan.add(no = task_m.new(arg: 10))
                    plan.add(yes = task_m.new)
                    assert_finds_tasks [yes], TaskMatcher.partially_instanciated
                    assert_finds_tasks [no], TaskMatcher.not_partially_instanciated
                end

                it 'deals with dynamic argument assignation' do
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

                it 'matches pending tasks' do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [t], TaskMatcher.pending
                    assert_finds_tasks [], TaskMatcher.not_pending
                    execute { t.start! }
                    assert_finds_tasks [], TaskMatcher.pending
                    assert_finds_tasks [t], TaskMatcher.not_pending
                end

                it 'matches starting tasks' do
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

                it 'matches running tasks' do
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

                it 'matches finishing tasks' do
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

                it 'matches successful tasks' do
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

                it 'matches failed tasks' do
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

                it 'matches finished tasks' do
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

                it 'matches reusable tasks set explicitly' do
                    plan.add(t = Roby::Tasks::Simple.new)
                    assert_finds_tasks [t], TaskMatcher.reusable
                    assert_finds_tasks [], TaskMatcher.not_reusable
                    t.do_not_reuse
                    assert_finds_tasks [], TaskMatcher.reusable
                    assert_finds_tasks [t], TaskMatcher.not_reusable
                end

                it 'matches tasks that are not reusable because they are finished' do
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
            end

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
