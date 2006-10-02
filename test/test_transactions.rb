require 'roby/transactions'
require 'test_plan.rb'

module PlanGeneration
    include Test::Unit::Assertions
    Plan = Roby::Plan
    TaskStructure = Roby::TaskStructure
    EventStructure = Roby::EventStructure
    include Roby::Transactions

    def random_plan(task_count = 10, task_relation_count = 5, event_relation_count = 5, task_classes = [Roby::Task])
	plan = Plan.new
	random_task_modifications(plan, task_count, 0, task_relation_count, 0, task_classes)
	random_event_modifications(plan, task_relation_count, 0)

	plan
    end

    def random_task_modifications(plan, new_tasks = 10, remove_tasks = 5, add_relation = 10, remove_relation = 5, task_classes = [Roby::Task])
	operations = (1..remove_tasks).map do
	    t = plan.known_tasks.random_element
	    plan.remove_task(t)
	    [plan, :remove_task, t]
	end

	operations += (1..new_tasks).map do 
	    t = task_classes.random_element.new
	    plan.discover(t)
	    [plan, :discover, t]
	end

	tasks = plan.known_tasks
	operations += remove_random_relations(Roby::TaskStructure.relations, remove_relation)
	operations += add_random_relations(Roby::TaskStructure.relations, add_relation) do 
	    [tasks.random_element, tasks.random_element]
	end

	operations
    end

    def random_event_modifications(plan, add_count = 10, remove_count = 5)
	operations = remove_random_relations(Roby::EventStructure.relations, remove_count)
	tasks = plan.known_tasks
	operations += add_random_relations(Roby::EventStructure.relations, add_count) do
	    (1..2).map { tasks.random_element.enum_for(:each_event, false).random_element }
	end

	operations
    end

    def add_random_relations(relations, count)
	(1..count).map do
	    rel = relations.random_element
	    n1, n2 = yield
	    next if n1 == n2

	    if !n1.directed_component(rel).include?(n2)
		n1.add_child_object(n2, rel)
		[n1, :add_child_object, n2, rel]
	    elsif !n2.directed_component(rel).include?(n1)
		n2.add_child_object(n1, rel)
		[n2, :add_child_object, n1, rel]
	    end
	end.compact
    end

    def remove_random_relations(relations, count)
	(1..count).map do
	    rel = relations.random_element
	    n1, n2, _ = rel.enum_for(:each_edge).random_element
	    next unless n1
	    n1.remove_child_object(n2, rel)
	    [n1, :remove_child_object, n2, rel]
	end.compact
    end

    def plan_save(plan)
	relations = TaskStructure.enum_for(:each_relation).map { |graph| [graph, graph.dup] }
	relations = Hash[*relations.flatten]
	event_relations = EventStructure.enum_for(:each_relation).map { |graph| [graph, graph.dup] }
	relations.merge Hash[*event_relations.flatten]

	backup = Plan.new(relations[TaskStructure::Hierarchy], [relations[TaskStructure::PlannedBy]])
	plan.missions.each { |t| backup.insert(t) }
	plan.known_tasks.each { |t| backup.discover(t) }
	assert_equal(plan.known_tasks, backup.known_tasks)

	[backup, relations]
    end

    def apply_on_backup(operations, backup)
	backup, relations = *backup

	pp operations.map { |_, x, _| x }
	operations.each do |obj, op, *args|
	    if Plan === obj
		return backup.send(op, *args)
	    elsif (op == :add_child_object || op == :remove_child_object)
		child, relation = *args
		obj   = obj.__getobj__ if Proxy === obj
		child = child.__getobj__ if Proxy === child
		return obj.send(op, child, relations[relation])
	    else
		raise "unknown operation #{op} on #{obj}"
	    end
	end
    end
end

# Check that a transaction behaves like a plan
class TC_TransactionAsPlan < Test::Unit::TestCase
    include TC_PlanStatic

    def setup
	@real_plan = Plan.new
	@plan = Transaction.new(@real_plan)
    end
    def teardown
	@plan.commit
    end
end


class TC_Transactions < Test::Unit::TestCase
    include Roby::Transactions

    def assert_is_proxy_of(object, wrapper, klass)
	assert_instance_of(klass, wrapper)
	assert_equal(object, wrapper.__getobj__)
    end

    def test_proxy_wrapping
	real_klass = Class.new do
	    define_method("forbidden") {}
	end

	proxy_klass = Class.new(DelegateClass(Object)) do
	    include Proxy

	    proxy_for real_klass
	    forbid_call :forbidden
	end

	obj   = real_klass.new
	proxy = Proxy.wrap(obj)
	assert_is_proxy_of(obj, proxy, proxy_klass)
	assert_same(proxy, Proxy.wrap(obj))

	proxy.discard
	# should allocate a new proxy object
	new_proxy = Proxy.wrap(obj)
	assert_not_same(proxy, new_proxy)

	# test == 
	assert_not_equal(proxy, new_proxy)
	assert_equal(proxy, obj)

	# check that may_wrap returns the object when wrapping cannot be done
	assert_raises(ArgumentError) { Proxy.wrap(10) }
	assert_equal(10, Proxy.may_wrap(10))

	# test forbid_call
	assert_raises(NotImplementedError) { proxy.forbidden }
    end

    def test_proxy_derived
	base_klass = Class.new
	derv_klass = Class.new(base_klass)
	proxy_base_klass = Class.new(DelegateClass(base_klass)) do
	    include Proxy
	    proxy_for base_klass
	end

	proxy_derv_klass = Class.new(DelegateClass(derv_klass)) do
	    include Proxy
	    proxy_for derv_klass
	end

	base_obj = base_klass.new
	assert_is_proxy_of(base_obj, Proxy.wrap(base_obj), proxy_base_klass)
	derv_obj = derv_klass.new
	assert_is_proxy_of(derv_obj, Proxy.wrap(derv_obj), proxy_derv_klass)
    end

    def test_proxy_class_selection
	task  = Roby::Task.new
	proxy = Proxy.wrap(task)

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
	task  = Class.new(Roby::Task) do
	    event :start, :command => true
	    event :intermediate, :command => true
	end.new
	proxy = Proxy.wrap(task)

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

    def test_task_proxy
	t1, t2 = (1..2).map { Roby::Task.new }
	p1, p2 = Proxy.wrap(t1), Proxy.wrap(t2)
	assert(p1.fullfills?(t1))
	assert(p1.fullfills?(p2))
    end

    def choose_vertex_pair(graph)
	all_vertices = graph.enum_for(:each_vertex).to_a
	assert(all_vertices.size >= 2)

	result = [all_vertices.shift, all_vertices.shift]
	all_vertices.each do |v|
	    idx = rand(4)
	    if idx < 2
		result[idx] = v
	    end
	end

	result
    end

    def assert_same_graph(expected, found, message = "")
	if expected != found
	    expected_vertices = expected.enum_for(:each_vertex).to_set
	    found_vertices = found.enum_for(:each_vertex).to_set
	    additional = found_vertices - expected_vertices
	    missing    = expected_vertices - found_vertices
	    message += "\nmissing vertices: #{missing.inspect}"
	    message += "\nadditional vertices: #{additional.inspect}"

	    expected_edges = expected.enum_for(:each_edge).to_set
	    found_edges = found.enum_for(:each_edge).to_set
	    additional = found_edges - expected_edges
	    missing    = expected_edges - found_edges
	    message += "\nmissing edges: #{missing.inspect}"
	    message += "\nadditional edges: #{additional.inspect}"

	    flunk message
	end
    end
    
    # Tests that the graph of proxys is separated from
    # the Task and EventGenerator graphs
    def test_proxy_graph_separation
	tasks = (1..4).map { Roby::Task.new }
	proxies = tasks.map { |t| Proxy.wrap(t) }

	t1, t2, t3, _ = tasks
	p1, p2, p3, _ = proxies
	p1.add_child_object(p2, Hierarchy)

	assert_equal([], t1.enum_for(:each_child_object, Hierarchy).to_a)
	t2.realized_by t3
	assert(! Hierarchy.linked?(p2, p3))
    end

    Hierarchy = Roby::TaskStructure::Hierarchy
    def test_discover
	tasks = (1..4).map { Roby::Task.new }

	root, t1, t2, t03, _ = tasks
	root.realized_by t1
	root.realized_by t2
	t1.realized_by t03
	t2.realized_by t03
	assert(Hierarchy.linked?(root, t1))
	assert(root.child_object?(t1, Hierarchy))

	wroot = Proxy.wrap(root)
	wt1   = Proxy.wrap(t1)
	assert(! wroot.discovered?(Hierarchy))
	assert(! Hierarchy.linked?(wroot, wt1))
	assert(wroot.child_object?(wt1, Hierarchy))
	assert_equal([wt1, Proxy.wrap(t2)].to_set, wroot.enum_for(:each_child_object, Hierarchy).to_set)
	assert(wroot.discovered?(Hierarchy))
	assert(! wt1.discovered?(Hierarchy))

	wt03 = Proxy.wrap(t03)
	wt2 = Proxy.wrap(t2)
	wt03.each_child_object(Hierarchy) { }
	assert(wt03.discovered?(Hierarchy))
	assert(Hierarchy.linked?(wt2, wt03))
    end

    def transaction(plan)
	trsc = Roby::Transaction.new(plan)
	yield(trsc)
	trsc.commit
    end

    # Tests insertion and removal of tasks
    def test_add_remove
	plan = Roby::Plan.new
	t1, t2, t3 = (1..3).map { Roby::Task.new }
	plan.insert(t1)

	transaction(plan) do |trsc|
	    assert(trsc.include?(t1))
	    assert(trsc.mission?(t1))
	    assert(trsc.include?(Proxy.wrap(t1)))
	    assert(trsc.mission?(Proxy.wrap(t1)))
	end

	transaction(plan) do |trsc| 
	    trsc.discover(t3)
	    assert(trsc.include?(t3))
	    assert(!trsc.mission?(t3))
	    assert(!plan.include?(t3))
	    assert(!plan.mission?(t3))
	end
	assert(plan.include?(t3))
	assert(!plan.mission?(t3))

	transaction(plan) do |trsc| 
	    trsc.insert(t2) 
	    assert(trsc.include?(t2))
	    assert(trsc.mission?(t2))
	    assert(!plan.include?(t2))
	    assert(!plan.mission?(t2))
	end
	assert(plan.include?(t2))
	assert(plan.mission?(t2))

	transaction(plan) do |trsc|
	    trsc.discard(t2)
	    assert(trsc.include?(t2))
	    assert(!trsc.mission?(t2))
	    assert(plan.include?(t2))
	    assert(plan.mission?(t2))
	end
	assert(plan.include?(t2))
	assert(!plan.mission?(t2))

	transaction(plan) do |trsc|
	    trsc.remove_task(Proxy.wrap(t3)) 
	    assert(!trsc.include?(t3))
	    assert(plan.include?(t3))
	end
	assert(!plan.include?(t3))
	assert(!plan.mission?(t3))
    end
end

