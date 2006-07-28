
require 'test_config'
require 'test/unit'

require 'roby'
require 'roby/plan'

class TC_Plan < Test::Unit::TestCase
    include Roby
    def test_base
	plan = Plan.new
	task_model = Class.new(Task) do 
	    event :start
	    event :stop, :command => true
	end

	t1, t2, t3 = 3.enum_for(:times).map { task_model.new }
	t1.realized_by t2
	t2.on(:start, t3, :stop)

	plan.insert(t1)
	tasks = plan.tasks
	assert( tasks.include?(t1) )
	assert( tasks.include?(t2) )
	assert( tasks.include?(t3) )
    end

    def test_query_fullfills
	task_model = Class.new(Task) do
	    event(:start)
	end
	TC_Plan.const_set(:TaskModel, task_model)
	t1 = task_model.new(:value => 1)
	t2 = task_model.new(:value => 2)

	plan = Plan.new
	plan << t1 << t2

	result = Query.which_fullfills('TC_Plan::TaskModel').enum_for(:each, plan).to_set
	assert_equal([t1, t2].to_set, result)

	result = Query.which_fullfills('TC_Plan::TaskModel', :value => 1).enum_for(:each, plan).to_set
	assert_equal([t1].to_set, result)

	result = plan.find_tasks.which_fullfills('TC_Plan::TaskModel', :value => 2).to_set
	assert_equal([t2].to_set, result)

	assert_marshallable(Query.new)
    end
end

