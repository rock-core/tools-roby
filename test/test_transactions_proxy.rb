require 'roby/transactions'
require 'test_plan.rb'

class TC_TransactionsProxy < Test::Unit::TestCase
    include Roby::Transactions
    include CommonTestBehaviour

    attr_reader :transaction, :plan
    def setup
	@plan = Roby::Plan.new
	@transaction = Roby::Transaction.new(plan)
	super
    end
    def teardown
	transaction.discard_transaction
	super
    end

    def assert_is_proxy_of(object, wrapper, klass)
	assert_instance_of(klass, wrapper)
	assert_equal(object, wrapper.__getobj__)
    end

    def test_proxy_wrapping
	real_klass = Class.new do
	    define_method("forbidden") {}
	end

	proxy_klass = Class.new do
	    include Proxy

	    proxy_for real_klass
	    forbid_call :forbidden
	    def clear_vertex; end
	end

	obj   = real_klass.new
	proxy = transaction[obj]
	assert_is_proxy_of(obj, proxy, proxy_klass)
	assert_same(proxy, transaction[obj])

	# proxy.discard
	# # should allocate a new proxy object
	# new_proxy = transaction[obj]
	# assert_not_same(proxy, new_proxy)

	# # test == 
	# assert_not_equal(proxy, new_proxy)
	# assert_equal(proxy, obj)

	# check that may_wrap returns the object when wrapping cannot be done
	assert_raises(ArgumentError) { transaction[10] }
	assert_equal(10, transaction.may_wrap(10))

	# test forbid_call
	assert_raises(NotImplementedError) { proxy.forbidden }
    end

    def test_proxy_derived
	base_klass = Class.new
	derv_klass = Class.new(base_klass)
	proxy_base_klass = Class.new do
	    include Proxy
	    proxy_for base_klass
	    def clear_vertex; end
	end

	proxy_derv_klass = Class.new do
	    include Proxy
	    proxy_for derv_klass
	    def clear_vertex; end
	end

	base_obj = base_klass.new
	assert_is_proxy_of(base_obj, transaction[base_obj], proxy_base_klass)
	derv_obj = derv_klass.new
	assert_is_proxy_of(derv_obj, transaction[derv_obj], proxy_derv_klass)
    end

    def test_proxy_class_selection
	task  = Roby::Task.new
	proxy = transaction[task]

	assert_is_proxy_of(task, proxy, Task)

	start_event = proxy.event(:start)
	assert_is_proxy_of(task.event(:start), start_event, EventGenerator)

	proxy.event(:stop)
	proxy.event(:success)
	proxy.each_event do |proxy_event|
	    assert_is_proxy_of(task.event(proxy_event.symbol), proxy_event, EventGenerator)
	end
    end

    def test_proxy_disables_command
	task  = Class.new(SimpleTask) do
	    event :intermediate, :command => true
	end.new
	proxy = transaction[task]

	assert_nothing_raised { task.event(:start).emit(nil) }
	assert_nothing_raised { task.intermediate!(nil) }
	assert_raises(NotImplementedError) { proxy.event(:start).emit(nil) }
	assert_raises(NotImplementedError) { proxy.emit(:start) }
	assert_raises(NotImplementedError) { proxy.start!(nil) }

	# Check that events that are only in the subclass of Task
	# are forbidden
	assert_raises(NotImplementedError) { proxy.intermediate!(nil) }

	# Check that dynamic events are forbidden
	task.model.class_eval { event(:dynamic, :command => true) }
	assert_nothing_raised { task.dynamic!(nil) }
	assert_raises(NotImplementedError) { proxy.dynamic!(nil) }
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
	tasks = (1..4).map { Roby::Task.new }
	proxies = tasks.map { |t| transaction[t] }

	t1, t2, t3, _ = tasks
	p1, p2, p3, _ = proxies
	p1.add_child_object(p2, Hierarchy)

	assert_equal([], t1.enum_for(:each_child_object, Hierarchy).to_a)
	t2.realized_by t3
	assert(! Hierarchy.linked?(p2, p3))
    end

    Hierarchy = Roby::TaskStructure::Hierarchy
    def task_pair
	t1 = Roby::Task.new
	t2 = Roby::Task.new
	yield(t1, t2, transaction[t1], transaction[t2])
    end

    def test_discover_tasks
	task_pair do |t, t2, p, p2|
	    t.realized_by t2

	    assert(! p.discovered?(Hierarchy))
	    assert(! p2.discovered?(Hierarchy))
	    assert(! Hierarchy.linked?(p, p2))

	    p.discover(Hierarchy)

	    assert(Hierarchy.linked?(p, p2))
	    assert(p.discovered?(Hierarchy))
	    assert(!p2.discovered?(Hierarchy))
	end
    end

    def test_discover_metafunction
	task_pair do |t, t2, p, p2|
	    t.realized_by t2
	    p.parent_object?(p2, Hierarchy)

	    assert(Hierarchy.linked?(p, p2))
	    assert(p.discovered?(Hierarchy))
	    assert(!p2.discovered?(Hierarchy))
	end
    end


    def event_pair
	ev = Roby::EventGenerator.new(true)
	ev2 = Roby::EventGenerator.new(true)
	yield(ev, ev2, transaction[ev], transaction[ev2])
    end
    def test_discover_events
	event_pair do |ev, ev2, proxy, proxy2|
	    proxy.on ev2
	    assert(proxy.discovered?(Roby::EventStructure::Signal))
	end
	event_pair do |ev, ev2, proxy, proxy2|
	    ev2.on proxy
	    assert(proxy.discovered?(Roby::EventStructure::Signal))
	end
	event_pair do |ev, ev2, proxy, proxy2|
	    proxy2.on proxy
	    assert(proxy.discovered?(Roby::EventStructure::Signal))
	    assert(proxy2.discovered?(Roby::EventStructure::Signal))
	end
    end
end

