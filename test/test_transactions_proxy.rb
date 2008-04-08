$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'

class TC_TransactionsProxy < Test::Unit::TestCase
    include Roby::Transactions
    include Roby::Test

    attr_reader :transaction
    def setup
	@transaction = Roby::Transaction.new(plan)
	super
    end
    def teardown
	transaction.discard_transaction
	super
    end

    def test_wrapping_free_objects
	task = SimpleTask.new
	assert_same(task, transaction[task])
	assert_equal(transaction, task.plan)
	ev   = EventGenerator.new
	assert_same(ev, transaction[ev])
	assert_equal(transaction, ev.plan)
    end

    def test_task_proxy
	plan.insert(t = Roby::Task.new)
	p = transaction[t]
	assert_equal(p, p.root_object)
	assert(p.root_object?)

	wrapped_start = transaction[t.event(:start)]
	assert_kind_of(Roby::Transactions::TaskEventGenerator, wrapped_start)
	assert_equal(p, wrapped_start.root_object)
	assert(!wrapped_start.root_object?)
	assert_equal(wrapped_start, p.event(:start))

	wrapped_stop = p.event(:stop)
	assert_equal(transaction[t.event(:stop)], wrapped_stop)
    end
    
    def test_event_proxy
	plan.discover(ev = EventGenerator.new)
	wrapped = transaction[ev]
	assert_kind_of(Roby::Transactions::EventGenerator, wrapped)
	assert_equal(plan, ev.plan)
	assert_equal(transaction, wrapped.plan)
	assert(wrapped.root_object?)
    end

    def assert_is_proxy_of(object, wrapper, klass)
	assert(wrapper.model.has_ancestor?(klass))
	assert_equal(object, wrapper.__getobj__)
    end

    def test_proxy_wrapping
	real_klass = Class.new(Roby::EventGenerator) do
	    define_method("forbidden") {}
	end

	proxy_klass = Class.new(Roby::EventGenerator) do
	    include Roby::Transactions::Proxy

	    proxy_for real_klass
	    def clear_vertex; end
	end

	plan.discover(obj = real_klass.new)
	proxy = transaction[obj]
	assert_is_proxy_of(obj, proxy, proxy_klass)
	assert_same(proxy, transaction[obj])
	assert_same(proxy, transaction.wrap(obj, false))

	# check that may_wrap returns the object when wrapping cannot be done
	assert_raises(TypeError) { transaction[10] }
	assert_equal(10, transaction.may_wrap(10))
    end

    def test_proxy_derived
	base_klass = Class.new(Roby::EventGenerator)
	derv_klass = Class.new(base_klass)
	proxy_base_klass = Class.new(Roby::EventGenerator) do
	    include Roby::Transactions::Proxy
	    proxy_for base_klass
	    def clear_vertex; end
	end

	proxy_derv_klass = Class.new(Roby::EventGenerator) do
	    include Roby::Transactions::Proxy
	    proxy_for derv_klass
	    def clear_vertex; end
	end


	base_obj = base_klass.new
	base_obj.plan = plan
	assert_is_proxy_of(base_obj, transaction[base_obj], proxy_base_klass)
	derv_obj = derv_klass.new
	derv_obj.plan = plan
	assert_is_proxy_of(derv_obj, transaction[derv_obj], proxy_derv_klass)
    end

    def test_proxy_class_selection
	task  = Roby::Task.new
	plan.discover(task)
	proxy = transaction[task]

	assert_is_proxy_of(task, proxy, Task)

	start_event = proxy.event(:start)
	assert_is_proxy_of(task.event(:start), start_event, TaskEventGenerator)

	proxy.event(:stop)
	proxy.event(:success)
	proxy.each_event do |proxy_event|
	    assert_is_proxy_of(task.event(proxy_event.symbol), proxy_event, TaskEventGenerator)
	end
    end

    def test_proxy_not_executable
	task  = Class.new(SimpleTask) do
	    event :intermediate, :command => true
	end.new
	plan.discover(task)
	proxy = transaction[task]

	assert_nothing_raised { task.event(:start).emit(nil) }
	assert_nothing_raised { task.intermediate!(nil) }
	assert(!proxy.executable?)
	assert(!proxy.event(:start).executable?)
	assert_raises(EventNotExecutable) { proxy.event(:start).emit(nil) }
	assert_raises(EventNotExecutable) { proxy.emit(:start) }
	assert_raises(EventNotExecutable) { proxy.start!(nil) }

	# Check that events that are only in the subclass of Task
	# are forbidden
	assert_raises(EventNotExecutable) { proxy.intermediate!(nil) }
    end

    def test_proxy_fullfills
	t1, t2 = (1..2).map { Roby::Task.new }
	p1, p2 = transaction[t1], transaction[t2]
	assert(p1.fullfills?(t1))
	assert(p1.fullfills?(p2))
    end

    # Tests that the graph of proxys is separated from
    # the Task and EventGenerator graphs
    def test_proxy_graph_separation
	tasks = prepare_plan :discover => 3
	proxies = tasks.map { |t| transaction[t] }

	t1, t2, t3 = tasks
	p1, p2, p3 = proxies
	p1.realized_by p2

	assert_equal([], t1.enum_for(:each_child_object, Hierarchy).to_a)
	t2.realized_by t3
	assert(! Hierarchy.linked?(p2, p3))
    end

    def test_proxy_plan
	task = Roby::Task.new
	plan.insert(task)

	proxy = transaction[task]
	assert_equal(plan, task.plan)
	assert_equal(plan, task.event(:start).plan)
	assert_equal(transaction, proxy.plan)
	assert_equal(transaction, proxy.event(:start).plan)
    end

    Hierarchy = Roby::TaskStructure::Hierarchy

    def test_task_relation_copy
	t1, t2 = prepare_plan :discover => 2
	t1.realized_by t2

	p1 = transaction[t1]
	assert(p1.leaf?, p1.children)
	p2 = transaction[t2]
	assert([p2], p1.children.to_a)
    end

    def test_task_events
	t1, t2 = prepare_plan :discover => 2
	t1.on(:success, t2, :start)

	p1 = transaction[t1]
	assert(p1.event(:success).leaf?(EventStructure::Signal))

	p2 = transaction[t2]
	assert([p2.event(:start)], p1.event(:success).child_objects(EventStructure::Signal).to_a)
    end
end

