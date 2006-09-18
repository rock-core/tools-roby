
require 'test_config'
require 'test/unit'

require 'roby'
require 'roby/plan'

class TC_Plan < Test::Unit::TestCase
    include Roby
    def test_base
	task_model = Class.new(Task) do 
	    event :start
	    event :stop, :command => true
	end

	t1, t2, t3 = 3.enum_for(:times).map { task_model.new }
	t1.realized_by t2
	t2.on(:start, t3, :stop)

	plan = Plan.new
	plan.insert(t1)
	assert( plan.include?(t1) )
	assert( plan.include?(t2) )
	assert( !plan.include?(t3) )
    end

    def test_query_fullfills
	task_model = Class.new(Task) do
	    event(:start)
	end
	TC_Plan.const_set(:TaskModel, task_model)
	t1 = task_model.new(:value => 1)
	t2 = task_model.new(:value => 2)

	plan = Plan.new
	assert(plan.insert(t1))
	plan.insert(t2)
	assert(plan.include?(t1))

	result = Query.which_fullfills('TC_Plan::TaskModel').enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)

	result = Query.which_fullfills('TC_Plan::TaskModel', :value => 1).enum_for(:each, plan).to_set
	assert_equal([t1].to_set, result)

	result = plan.find_tasks.which_fullfills('TC_Plan::TaskModel', :value => 2).to_set
	assert_equal([t2].to_set, result)

	assert_marshallable(Query.new)
    end

    def test_query_information
	t1 = Class.new(Task) do
	    event(:start)
	    needs :source_info
	    improves :other_info
	end.new
	t2 = Class.new(Task) do
	    event(:start)
	    needs :source_info
	    improves :yet_another_info
	end.new

	plan = Plan.new
	plan << t1 << t2
	result = Query.which_needs(:source_info).enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)
	result = Query.which_needs(:foo_bar).enum_for(:each, plan).to_set
	assert_equal(Set.new, result)
	result = Query.which_improves(:foo_bar).enum_for(:each, plan).to_set
	assert_equal(Set.new, result)
	result = Query.which_improves(:other_info).enum_for(:each, plan).to_set
	assert_equal([t1].to_set, result)
	result = Query.which_needs(:source_info).which_improves(:yet_another_info).enum_for(:each, plan).to_set
	assert_equal([t2].to_set, result)
    end
end

