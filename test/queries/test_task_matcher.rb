require 'roby/test/self'
require 'roby/tasks/simple'

class TC_Query < Minitest::Test
    TaskMatcher = Queries::TaskMatcher

    def check_matches_fullfill(task_model, plan, t0, t1, t2)
	result = TaskMatcher.new.enum_for(:each, plan).to_set
	assert_equal([t1, t2, t0].to_set, result)
	result = TaskMatcher.new.with_model(Roby::Task).enum_for(:each, plan).to_set
	assert_equal([t1, t2, t0].to_set, result, plan.task_index.by_model)

	result = TaskMatcher.which_fullfills(task_model).enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)

	result = TaskMatcher.with_model(task_model).enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)
	result = TaskMatcher.with_arguments(:value => 1).enum_for(:each, plan).to_set
	assert_equal([t0, t1].to_set, result)

	result = TaskMatcher.which_fullfills(task_model, :value => 1).enum_for(:each, plan).to_set
	assert_equal([t1].to_set, result)

	verify_is_droby_marshallable_object(TaskMatcher.new.which_fullfills(task_model, :value => 2))
    end

    def test_match_task_fullfills
	task_model = Task.new_submodel do
	    argument :value
	end

	t0 = Roby::Task.new(:value => 1)
	t1 = task_model.new(:value => 1)
	t2 = task_model.new(:value => 2)

	plan.add_mission(t0)
	plan.add_mission(t1)
	plan.add_mission(t2)

	check_matches_fullfill(task_model, plan, t0, t1, t2)
    end

    def test_match_tag
        tag = TaskService.new_submodel
        tag.argument :id
	task_model = Tasks::Simple.new_submodel
        task_model.provides tag

        plan.add(task = task_model.new(:id => 3))
        assert(Task.match(tag)              === task)
        assert(Task.match(tag, :id => 3)    === task)
        assert(! (Task.match(tag, :id => 2) === task))

        plan.add(task = Tasks::Simple.new)
        assert(! (Task.match(tag)           === task))
        assert(! (Task.match(tag, :id => 3) === task))
        assert(! (Task.match(tag, :id => 2) === task))
    end

    def test_match_proxy_fullfills
	task_model = Task.new_submodel do
	    argument :value
	end

	t0 = Roby::Task.new(:value => 1)
	t1 = task_model.new(:value => 1)
	t2 = task_model.new(:value => 2)

	plan.add_mission(t0)
	plan.add_mission(t1)
	plan.add_mission(t2)

        plan.in_transaction do |trsc|
            check_matches_fullfill(task_model, trsc, trsc[t0], trsc[t1], trsc[t2])
        end
    end

    def assert_finds_tasks(task_set, msg = "")
	assert_equal(task_set.to_set, yield.enum_for(:each, plan).to_set, msg)
    end

    def test_query_predicates
	t1 = Tasks::Simple.new_submodel { argument :fake }.new
	t2 = Roby::Task.new
	plan.add [t1, t2]

	assert_finds_tasks([]) { TaskMatcher.executable }
	assert_finds_tasks([t1,t2]) { TaskMatcher.not_executable }
	assert_finds_tasks([t2]) { TaskMatcher.abstract }
	assert_finds_tasks([t1]) { TaskMatcher.partially_instanciated }
	assert_finds_tasks([t2]) { TaskMatcher.fully_instanciated }
	t1.arguments[:fake] = 2
	assert_finds_tasks([t1, t2]) { TaskMatcher.fully_instanciated }
	assert_finds_tasks([t2]) { TaskMatcher.fully_instanciated.abstract }

	assert_finds_tasks([t1, t2]) { TaskMatcher.pending }
	t1.start!
	assert_finds_tasks([t2]) { TaskMatcher.pending }
	assert_finds_tasks([t1, t2]) { TaskMatcher.not_failed }
	assert_finds_tasks([t1, t2]) { TaskMatcher.not_success }
	assert_finds_tasks([t1, t2]) { TaskMatcher.not_finished }

	assert_finds_tasks([t1]) { TaskMatcher.running }
	t1.success!
	assert_finds_tasks([t1], plan.task_index.by_predicate) { TaskMatcher.success }
	assert_finds_tasks([t1]) { TaskMatcher.finished }
	assert_finds_tasks([t1, t2]) { TaskMatcher.not_failed }
	assert_finds_tasks([t2]) { TaskMatcher.not_finished }

	plan.remove_object(t1)

	t1 = Tasks::Simple.new
	plan.add(t1)
	t1.start!
	t1.failed!
	assert_finds_tasks([t1]) { TaskMatcher.failed }
	assert_finds_tasks([t1]) { TaskMatcher.finished }
	assert_finds_tasks([t1]) { TaskMatcher.finished.not_success }
    end

    def test_it_does_not_allow_specifying_different_constraints_on_the_same_argument
        matcher = Tasks::Simple.match.with_arguments(:id => 1)
        assert_raises(ArgumentError) { matcher.with_arguments(:id => 2) }
    end
end



