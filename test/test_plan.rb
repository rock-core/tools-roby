
require 'test_config'
require 'test/unit'

require 'roby'
require 'roby/plan'

class TC_Plan < Test::Unit::TestCase
    include Roby
    def test_base
	task_model = Class.new(Task) do 
	    event :stop, :command => true
	end

	t1, t2, t3, t4 = 4.enum_for(:times).map { task_model.new }
	t1.realized_by t2
	t2.on(:start, t3, :stop)
	t2.planned_by t4

	plan = Plan.new
	result = plan.insert(t1)
	assert_equal(plan, result)
	assert( plan.include?(t1) )
	assert( plan.include?(t2) )
	assert( !plan.include?(t3) ) # t3 not related because of hierarchy
	assert( plan.include?(t4) )

	assert( plan.mission?(t1) )
	assert( !plan.mission?(t2) )

	assert_equal([t1, t2, t4].to_value_set, plan.useful_tasks)
	plan.insert(t3)
	assert_equal([t1, t2, t3, t4].to_value_set, plan.useful_tasks)
	plan.discard(t1)
	assert_equal([t3].to_value_set, plan.useful_tasks)
	assert_equal([t1, t2, t4].to_value_set, plan.unneeded_tasks)
    end

    def test_query_fullfills
	task_model = Class.new(Task)
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
	    needs :source_info
	    improves :other_info
	end.new
	t2 = Class.new(Task) do
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
	result = Query.which_needs(:source_info).
	    which_improves(:yet_another_info).
	    enum_for(:each, plan).to_set

	assert_equal([t2].to_set, result)
    end

    def test_garbage_collect
	klass = Class.new(Task) do
	    attr_accessor :delays

	    event(:start, :command => true)
	    def stop(context)
		if delays
		    return
		else
		    emit(:stop)
		end
	    end
	    event(:stop)
	end

	tasks = (1..5).map { klass.new }
	t1, t2, t3, t4, t5 = *tasks
	t1.realized_by t3
	t2.realized_by t3
	t5.realized_by t4
	t3.realized_by t4

	plan = Class.new(Plan) do
	    attr_accessor :finalized_tasks
	    def finalized(task)
		@finalized_tasks << task
		super if defined? super
	    end
	end.new

	[t1, t2, t5].each { |t| plan.insert(t) }

	plan.finalized_tasks = []
	plan.garbage_collect
	assert_equal([], plan.finalized_tasks)

	plan.discard(t1)
	assert_equal([t1], plan.unneeded_tasks.to_a)
	plan.garbage_collect
	assert_equal([t1], plan.finalized_tasks)
	assert(! plan.include?(t1))

	plan.finalized_tasks = []
	t2.start!(nil)
	plan.discard(t2)
	plan.garbage_collect
	assert_equal([t2, t3], plan.finalized_tasks)

	plan.finalized_tasks = []
	t5.delays = true
	t5.start!(nil)
	plan.discard(t5)
	plan.garbage_collect
	assert_equal([], plan.finalized_tasks)
    end

    def test_replace
	klass = Class.new(Task) do
	    event(:start, :command => true)
	    event(:stop)
	    on :start => :stop
	end

	p, c1, c2, c3 = (1..4).map { klass.new }
	p.realized_by c1
	p.realized_by c2
	c1.on(:stop, c2, :start)

	plan = Plan.new
	plan.insert(p)
	plan.insert(c1)
	assert_nothing_raised { plan.replace(c1, c3) }
	assert(! plan.mission?(c1) )
	assert( plan.include?(c1) )
	plan.garbage_collect
	assert(! plan.include?(c1) )

	assert( p.child_object?(c3, TaskStructure::Hierarchy) )
	assert( !p.child_object?(c1, TaskStructure::Hierarchy) )
	assert( c3.event(:stop).child_object?(c2.event(:start), EventStructure::Signal) )
    end
end

