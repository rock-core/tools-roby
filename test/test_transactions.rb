require 'roby/transactions'

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
    
    def test_graph
	vertex = Class.new { include BGL::Vertex }
	base   = BGL::Graph.new

	# Add 200 vertices to +base+ and create 100 edges randomly
	200.times { base.insert(vertex.new) }
	(1..100).each do |i|
	    v1, v2 = choose_vertex_pair(base)
	    base.link(v1, v2) rescue nil
	end
	base_backup = base.dup
	result = base.dup
	assert_equal(result, base)

	# Create an empty transaction graph, and check that == works
	trsc = RelationGraph.new(base)
	assert_equal(base, trsc)

	# We now do a set of operations on both result and the transaction, and
	# check that they are always equal
	ops = [
	    Proc.new { |v1, v2, linked| [:link, v1, v2, nil] if !linked },
	    Proc.new { |v1, v2, linked| [:unlink, v1, v2] if linked },
	    Proc.new { |_, _| [:insert, vertex.new] },
	    Proc.new { |v1, _| [:remove, v1] }
	]
	
	history = []
	100.times do
	    v1, v2 = choose_vertex_pair(result)
	    op, *args = ops[rand(4)].call(v1, v2, result.linked?(v1, v2))
	    if op
		result.send(op, *args)
		trsc.send(op, *args)
		history << [op, *args].inspect
	    end
	    assert_same_graph(result, trsc, history.join("\n"))
	end

	assert_same_graph(base_backup, base)
	trsc.apply
	assert_same_graph(result, base)
    end
end

