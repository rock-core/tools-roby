require 'roby/test/self'

class TC_TransactionsProxy < Minitest::Test
    attr_reader :transaction
    def setup
	super
	@transaction = Roby::Transaction.new(plan)
    end
    def teardown
	transaction.discard_transaction
	super
    end

    def test_wrapping_free_objects
	task = Tasks::Simple.new
	assert_same(task, transaction[task])
	assert_equal(transaction, task.plan)
	ev   = EventGenerator.new
	assert_same(ev, transaction[ev])
	assert_equal(transaction, ev.plan)
    end

    def test_task_proxy
	plan.add_mission(t = Roby::Task.new)
        assert(!t.transaction_proxy?)
	p = transaction[t]
        assert(p.transaction_proxy?)

	assert_equal(p, p.root_object)
	assert(p.root_object?)
        assert_equal(transaction, p.plan)
        p.each_event do |ev|
            assert_equal(transaction, ev.plan)
        end

	wrapped_start = transaction[t.event(:start)]
	assert_kind_of(Roby::TaskEventGenerator::Proxying, wrapped_start)
        assert_equal(wrapped_start, p.event(:start))

	assert_equal(p, wrapped_start.root_object)
	assert(!wrapped_start.root_object?)
	assert_equal(wrapped_start, p.event(:start))

	wrapped_stop = p.event(:stop)
	assert_equal(transaction[t.event(:stop)], wrapped_stop)
    end
    
    def test_event_proxy
	plan.add(ev = EventGenerator.new)
	wrapped = transaction[ev]
	assert_kind_of(EventGenerator::Proxying, wrapped)
	assert_equal(plan, ev.plan)
	assert_equal(transaction, wrapped.plan)
	assert(wrapped.root_object?)
    end

    def assert_is_proxy_of(object, wrapper, klass)
	assert(wrapper.kind_of?(klass))
	assert_equal(object, wrapper.__getobj__)
    end

    def test_proxy_wrapping
	real_klass = Class.new(Roby::EventGenerator) do
	    define_method("forbidden") {}
	end

	proxy_klass = Module.new do
	    proxy_for real_klass
	    def clear_vertex; end
	end

	plan.add(obj = real_klass.new)
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
	proxy_base_klass = Module.new do
	    proxy_for base_klass
	    def clear_vertex; end
	end

	proxy_derv_klass = Module.new do
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
	plan.add(task)
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
	task  = Tasks::Simple.new_submodel do
	    event :intermediate, command: true
	end.new
	plan.add(task)
	proxy = transaction[task]

	task.event(:start).emit(nil)
	task.intermediate!(nil)
	assert(!proxy.executable?)
	assert(!proxy.event(:start).executable?)
	assert_raises(TaskEventNotExecutable) { proxy.event(:start).emit(nil) }
	assert_raises(TaskEventNotExecutable) { proxy.emit(:start) }
	assert_raises(TaskEventNotExecutable) { proxy.start!(nil) }

	# Check that events that are only in the subclass of Task
	# are forbidden
	assert_raises(TaskEventNotExecutable) { proxy.intermediate!(nil) }
    end

    def test_proxy_fullfills
        model = Roby::Task.new_submodel
        other_model = model.new_submodel
        tag   = Roby::TaskService.new_submodel do
            argument :id
            argument :other
        end
        model.include(tag)

        t = model.new id: 10
        p = transaction[t]

        assert(p.fullfills?(model))
        assert(p.fullfills?(tag))
        assert(p.fullfills?(model, id: 10))
        assert(p.fullfills?(tag, id: 10))
        assert(!p.fullfills?(other_model))
        assert(!p.fullfills?(model, id: 5))
        assert(!p.fullfills?(tag, id: 5))

        assert(!p.fullfills?(model, id: 10, other: 20))
        p.arguments[:other] = 20
        assert(p.fullfills?(model, id: 10, other: 20))

    end

    # Tests that the graph of proxys is separated from
    # the Task and EventGenerator graphs
    def test_proxy_graph_separation
	tasks = prepare_plan add: 3
	proxies = tasks.map { |t| transaction[t] }

	t1, t2, t3 = tasks
	p1, p2, p3 = proxies
	p1.depends_on p2

	assert_equal([], t1.enum_for(:each_child_object, Dependency).to_a)
	t2.depends_on t3
	assert(! Dependency.linked?(p2, p3))
    end

    def test_proxy_plan
	task = Roby::Task.new
	plan.add_mission(task)

	proxy = transaction[task]
	assert_equal(plan, task.plan)
	assert_equal(plan, task.event(:start).plan)
	assert_equal(transaction, proxy.plan)
	assert_equal(transaction, proxy.event(:start).plan)
    end

    Dependency = Roby::TaskStructure::Dependency

    def test_task_relation_copy
	t1, t2 = prepare_plan add: 2
	t1.depends_on t2

	p1 = transaction[t1]
	assert(p1.leaf?(TaskStructure::Dependency), "#{p1} should have been a leaf, but has the following chilren: #{p1.children.map(&:to_s).join(", ")}")
	p2 = transaction[t2]
	assert_equal([p2], p1.children.to_a)
    end

    def test_task_events
	t1, t2 = prepare_plan add: 2
	t1.signals(:success, t2, :start)

	p1 = transaction[t1]
	assert(p1.event(:success).leaf?(EventStructure::Signal))

	p2 = transaction[t2]
	assert_equal([p2.event(:start)], p1.event(:success).child_objects(EventStructure::Signal).to_a)
    end
end

