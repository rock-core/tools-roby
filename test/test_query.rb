$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'mockups/tasks'
require 'flexmock'

class TC_Query < Test::Unit::TestCase
    include Roby::Test

    def test_query_fullfills
	task_model = Class.new(Task) do
	    argument :value
	end

	t0 = Roby::Task.new(:value => 1)
	t1 = task_model.new(:value => 1)
	t2 = task_model.new(:value => 2)

	plan.insert(t0)
	plan.insert(t1)
	plan.insert(t2)

	result = TaskMatcher.new.enum_for(:each, plan).to_set
	assert_equal([t1, t2, t0].to_set, result)
	result = TaskMatcher.new.with_model(Roby::Task).enum_for(:each, plan).to_set
	assert_equal([t1, t2, t0].to_set, result)

	result = TaskMatcher.which_fullfills(task_model).enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)

	result = TaskMatcher.with_model(task_model).enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)
	result = TaskMatcher.with_arguments(:value => 1).enum_for(:each, plan).to_set
	assert_equal([t0, t1].to_set, result)

	result = TaskMatcher.which_fullfills(task_model, :value => 1).enum_for(:each, plan).to_set
	assert_equal([t1].to_set, result)

	result = plan.find_tasks.which_fullfills(task_model, :value => 2).to_set
	assert_equal([t2].to_set, result)

	assert_marshallable(TaskMatcher.new.which_fullfills(task_model, :value => 2))
    end

    def test_query_information
	t1 = Class.new(Task) do
	    needs :source_info
	    improves :other_info
	end.new
	t2 = Class.new(Task) do
	    needs :source_info
	    improves :yet_another_info
	end.new

	plan << t1 << t2
	result = TaskMatcher.which_needs(:source_info).enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)
	result = TaskMatcher.which_needs(:foo_bar).enum_for(:each, plan).to_set
	assert_equal(Set.new, result)
	result = TaskMatcher.which_improves(:foo_bar).enum_for(:each, plan).to_set
	assert_equal(Set.new, result)
	result = TaskMatcher.which_improves(:other_info).enum_for(:each, plan).to_set
	assert_equal([t1].to_set, result)
	result = TaskMatcher.which_needs(:source_info).
	    which_improves(:yet_another_info).
	    enum_for(:each, plan).to_set

	assert_equal([t2].to_set, result)
    end

    def assert_finds_tasks(task_set)
	assert_equal(task_set.to_set, yield.enum_for(:each, plan).to_set)
    end

    def test_query_predicates
	t1 = Class.new(ExecutableTask) { argument :id }.new
	t2 = Roby::Task.new
	plan << t1 << t2

	assert_finds_tasks([]) { TaskMatcher.executable }
	assert_finds_tasks([t1,t2]) { TaskMatcher.not_executable }
	assert_finds_tasks([t2]) { TaskMatcher.abstract }
	assert_finds_tasks([t1]) { TaskMatcher.partially_instanciated }
	assert_finds_tasks([t2]) { TaskMatcher.fully_instanciated }
	t1.arguments[:id] = 2
	assert_finds_tasks([t1, t2]) { TaskMatcher.fully_instanciated }
	assert_finds_tasks([t2]) { TaskMatcher.fully_instanciated.abstract }
    end

    def test_negate
	t1 = Class.new(ExecutableTask) { argument :id }.new(:id => 1)
	t2 = Class.new(ExecutableTask) { argument :id }.new(:id => 2)
	t3 = Roby::Task.new
	plan << t1 << t2 << t3

	assert_finds_tasks([t3]) { (TaskMatcher.with_arguments(:id => 1) | TaskMatcher.with_arguments(:id => 2)).negate }
    end

    def test_or
	t1 = Class.new(ExecutableTask) { argument :id }.new(:id => 1)
	t2 = Class.new(ExecutableTask) { argument :id }.new(:id => 2)
	t3 = Roby::Task.new
	plan << t1 << t2 << t3

	assert_finds_tasks([t1, t2]) { TaskMatcher.with_arguments(:id => 1) | TaskMatcher.with_arguments(:id => 2) }
    end

    def test_and
	t1 = Class.new(ExecutableTask) { argument :id }.new(:id => 1)
	t2 = Class.new(ExecutableTask) { argument :id }.new(:id => 2)
	t3 = Roby::Task.new
	plan << t1 << t2 << t3

	assert_finds_tasks([t1, t2]) { TaskMatcher.fully_instanciated & TaskMatcher.executable }
	assert_finds_tasks([t1]) { (TaskMatcher.fully_instanciated & TaskMatcher.executable).with_arguments(:id => 1) }
	assert_finds_tasks([t3]) { TaskMatcher.fully_instanciated & TaskMatcher.abstract }
    end

end



