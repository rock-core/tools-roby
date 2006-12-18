require 'test_config'
require 'flexmock'

require 'roby/query'

class TC_Query < Test::Unit::TestCase
    include RobyTestCommon
    attr_reader :plan
    def setup
	@plan = Plan.new
	super
    end

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
end


