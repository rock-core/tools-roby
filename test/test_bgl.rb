$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'enumerator'
require 'flexmock'

class TC_BGL < Test::Unit::TestCase
    include Roby::SelfTest
    class Vertex
	include BGL::Vertex
    end
    Graph = BGL::Graph

    def test_vertex_graph_list
	graph = Graph.new
	v = Vertex.new
	graph.insert v
	assert_equal([graph], v.enum_for(:each_graph).to_a)

	graph.remove v
	assert_equal([], v.enum_for(:each_graph).to_a)
    end

    def setup_graph(vertex_count)
	graph = Graph.new
	vertices = (1..vertex_count).map do
	    graph.insert(v = Vertex.new)
	    v
	end
	[graph, vertices]
    end

    def test_graph_views
	g = Graph.new
	r = g.reverse
	assert_kind_of(Graph::Reverse, r)
	assert_equal(r.object_id, g.reverse.object_id)

	u = g.undirected
	assert_kind_of(Graph::Undirected, u)
	assert_equal(u.object_id, g.undirected.object_id)
    end

    def test_vertex_objects
	graph = Graph.new

	v1 = Vertex.new
	graph.insert v1
	assert(graph.include?(v1))
	assert_equal([v1], graph.enum_for(:each_vertex).to_a)

	graph.remove v1
	assert(!graph.include?(v1))
	assert_equal([], graph.enum_for(:each_vertex).to_a)

	g1, g2 = Graph.new, Graph.new
	g1.insert(v1)
	g2.insert(v1)
	v1.clear_vertex
	assert(!g1.include?(v1))
	assert(!g2.include?(v1))
    end

    def test_replace
	graph = Graph.new

	v1, v2, v3 = (1..3).map { Vertex.new }
	graph.link(v1, v2, 1)
	graph.link(v2, v3, 2)

	v4 = Vertex.new
	graph.replace_vertex(v2, v4)
	assert(! graph.linked?(v1, v2))
	assert(! graph.linked?(v2, v3))
	assert_equal(1, v1[v4, graph])
	assert_equal(2, v4[v3, graph])
    end

    def test_clear
	g1, g2 = Graph.new, Graph.new

	vertices = (1..3).map do
            g1.insert(v = Vertex.new)
            g2.insert(v)

            assert g1.include?(v)
            assert g2.include?(v)
            v
        end

        g1.clear
        vertices.each do |v|
            assert !g1.include?(v)
            assert g2.include?(v)
            assert_equal [g2], v.enum_for(:each_graph).to_a
        end
    end

    def test_edge_objects
	g1, g2 = Graph.new, Graph.new

	v1, v2, v3 = Vertex.new, Vertex.new, Vertex.new
	g1.link v1, v2, 1
	assert(g1.include?(v1))
	assert(g1.include?(v2))
	assert(g1.linked?(v1, v2))
	assert(!g1.linked?(v2, v1))

	g2.link v3, v2, 2
	assert_raises(ArgumentError) { g2.link v3, v2, 2 }
	assert_equal(2, v3[v2, g2])
	v3[v2, g2] = 3
	assert_equal(3, v3[v2, g2])

	g2.link v1, v2, 3
	assert(g1.linked?(v1, v2))
	assert_equal(3, v1[v2, g2])

	assert_raises(ArgumentError) { v2[v1, g1] }
	assert_raises(ArgumentError) { v3[v1, g1] }
	assert_raises(ArgumentError) { v1[v3, g1] }

	# Test enumerators
	assert_equal([[v1, v2, 1]], g1.enum_for(:each_edge).to_a)
	assert_equal([v2], v1.enum_for(:each_child_vertex).to_a)

	assert_equal([v1, v3].to_set, v2.enum_for(:each_parent_vertex).to_set)
	assert_equal([v1, v3].to_set, v2.enum_for(:each_parent_vertex, g2).to_set)
	assert_equal([v1].to_set, v2.enum_for(:each_parent_vertex, g1).to_set)

	assert_equal([v2], v3.enum_for(:each_child_vertex).to_a)
	assert_equal([v2], v3.enum_for(:each_child_vertex, g2).to_a)
	assert_equal([], v3.enum_for(:each_child_vertex, g1).to_a)

	# Test predicates
	#   .... on all graphs
	assert(!v1.parent_vertex?(v2))
	assert(v2.parent_vertex?(v1))
	assert(!v2.child_vertex?(v1))
	assert(v1.child_vertex?(v2))
	assert(v1.related_vertex?(v2))
	assert(v2.related_vertex?(v1))
	assert(v3.child_vertex?(v2))
	assert(v2.parent_vertex?(v3))

	#   .... on a specific subgraph
	assert(!v2.parent_vertex?(v3, g1))
	assert(v2.parent_vertex?(v3, g2))
    end

    def test_graph_root_p
	g1 = Graph.new
	v1, v2, v3, v4 = Vertex.new, Vertex.new, Vertex.new, Vertex.new
        g1.insert(v3)
	g1.link v1, v2, nil

        assert g1.root?(v1)
        assert !g1.root?(v2)
        assert g1.root?(v3)
        assert g1.root?(v4)
    end

    def test_graph_leaf_p
	g1 = Graph.new
	v1, v2, v3, v4 = Vertex.new, Vertex.new, Vertex.new, Vertex.new
	g1.link v1, v2, nil
        g1.insert(v3)

        assert !g1.leaf?(v1)
        assert g1.leaf?(v2)
        assert g1.leaf?(v3)
        assert g1.leaf?(v4)
    end

    def test_end_predicates
	g1, g2 = Graph.new, Graph.new

	v1, v2, v3, v4 = Vertex.new, Vertex.new, Vertex.new, Vertex.new
	g1.link v1, v2, nil
	g2.link v2, v1, nil
	assert( !v1.root? )
	assert( !v1.leaf? )
	assert( v1.root?(g1) )
	assert( v2.leaf?(g1) )

	g1.link(v3, v1, nil)
	assert(v3.root?)
	g2.link(v3, v2, nil)
	assert(v3.root?)

	g1.link(v1, v4, nil)
	assert(v4.leaf?)
	g2.link(v2, v4, nil)
	assert(v4.leaf?)
    end

    def assert_components(expected, found)
	# Equality of set-of-set does not work, don't know why
	assert_equal(expected.map { |c| c.sort_by { |e| e.object_id } }.to_set, 
		     found.map { |c| c.sort_by { |e| e.object_id } }.to_set)
    end

    def test_graph_components
	graph = Graph.new

	vertices = (1..5).map { Vertex.new }
	v5 = vertices.pop
	v1, v2, v3, v4 = *vertices
	vertices.each { |v| graph.insert(v) }

	graph.link v1, v2, nil
	assert_components([[v1, v2], [v3], [v4]], graph.components)
	assert_raises(ArgumentError) { graph.components(nil, false) }
	assert_components([[v1, v2]], graph.components([v1].to_value_set))
	assert_components([[v5]], graph.components([v5].to_value_set))
	assert_components([], graph.components([v5].to_value_set, false))
	assert_components([[v2, v1]], graph.generated_subgraphs([v1].to_value_set))
	assert_components([[v2, v1]], graph.generated_subgraphs([v1].to_value_set, false))
	assert_components([[v2]], graph.generated_subgraphs([v2].to_value_set))
	assert_components([], graph.generated_subgraphs([v2].to_value_set, false))
	assert_components([[v2], [v5]], graph.generated_subgraphs([v2, v5].to_value_set))

	assert_components([], graph.generated_subgraphs([v2].to_value_set, false))
	assert_components([], graph.generated_subgraphs([v2].to_value_set, false))
	assert_components([], graph.generated_subgraphs([v2, v5].to_value_set, false))
	assert_components([[v1, v2]], graph.reverse.generated_subgraphs([v2].to_value_set))
	assert_components([[v4]], graph.components([v4].to_value_set))
	assert_components([], graph.components([v4].to_value_set, false))

	graph.link v4, v3, nil
	assert_components([[v1, v2], [v4, v3]], graph.components)
	assert_components([[v2], [v3]], graph.generated_subgraphs([v2, v3].to_value_set))
	assert_components([], graph.generated_subgraphs([v3, v2].to_value_set, false))
	assert_components([[v1, v2], [v4, v3]], graph.reverse.generated_subgraphs([v2, v3].to_value_set))
	assert_components([[v1, v2], [v4, v3]], graph.reverse.generated_subgraphs([v2, v3].to_value_set, false))
	assert_components([[v3, v4]], graph.generated_subgraphs([v4].to_value_set))
	assert_components([[v3, v4]], graph.generated_subgraphs([v4].to_value_set, false))

	graph.link v1, v3, nil
	assert_components([[v1, v2, v3, v4]], graph.components)
	assert_components([[v1, v2, v3, v4]], graph.components([v1].to_value_set))

	g2 = Graph.new
	graph.unlink v4, v3
	g2.link v4, v3, nil
	assert_components([[v4]], graph.components([v4].to_value_set))
	# assert_components([], graph.components([v4], false))
	assert_components([[v4, v3]], g2.components([v3].to_value_set))

	v5 = Vertex.new
	# Check that we get a singleton component even if v5 is not in the graph
	assert_components([[v5]], graph.components([v5].to_value_set))
	# assert_components([], graph.components([v5], false))
    end

    def test_vertex_component
	graph = Graph.new

	vertices = (1..4).map { Vertex.new }
	v1, v2, v3, v4 = *vertices
	vertices.each { |v| graph.insert(v) }

	graph.link v1, v2, nil
	graph.link v3, v2, nil
	graph.link v3, v4, nil
	graph.link v2, v4, nil
	assert_components([[v1, v2, v3, v4]], graph.components([v1].to_value_set))
	assert_components([[v1, v2, v3, v4]], graph.components([v2].to_value_set))

	g2 = Graph.new
	g2.link v4, v3, nil
	assert_components([[v4, v3]], g2.components([v4].to_value_set))
    end

    def test_dup
	graph = Graph.new

	vertices = (1..4).map { Vertex.new }
	v1, v2, v3, v4 = *vertices
	vertices.each { |v| graph.insert(v) }

	graph.link v1, v2, nil
	graph.link v3, v2, nil
	graph.link v3, v4, nil
	graph.link v2, v4, nil

	copy = graph.dup
	assert_not_same(copy, graph)
	assert(copy.same_graph?(graph))

	vertices.each do |v|
	    assert( [graph, copy].to_set, v.enum_for(:each_graph).map(&:to_s).join(", ") )
	end
    end

    def assert_bfs_trace(expected, sets, trace)
	trace = trace.to_a
	current_index = 0
	sets.each do |s|
	    s = (s..s) if Fixnum === s
	    range_size = s.to_a.size
	    assert_equal(expected[s].to_set, trace[current_index, range_size].to_set)
	    current_index += range_size
	end
    end

    def test_each_bfs
	graph = Graph.new

	vertices = (1..4).map { Vertex.new }
	v1, v2, v3, v4 = *vertices
	vertices.each { |v| graph.insert(v) }

	graph.link v1, v2, 1
	graph.link v1, v3, 2
	graph.link v2, v3, 3
	graph.link v3, v4, 4
	graph.link v4, v2, 5

	#
	# v1 ----->v3--->v4
	#  |-->v2--^      |
	#       ^---------|

	trace = [
	    [v1, v2, 1, Graph::TREE], 
	    [v1, v3, 2, Graph::TREE], 
	    [v2, v3, 3, Graph::NON_TREE], 
	    [v3, v4, 4, Graph::TREE],
	    [v4, v2, 5, Graph::NON_TREE]
	]
	assert_bfs_trace(trace, [0..1, 2..3, 4], graph.enum_for(:each_bfs, v1, Graph::ALL))
	assert_bfs_trace(trace, [0..1, 3], graph.enum_for(:each_bfs, v1, Graph::TREE))
	assert_bfs_trace(trace, [2, 4], graph.enum_for(:each_bfs, v1, Graph::NON_TREE))
	assert_raises(ArgumentError) { graph.each_bfs(v1, Graph::FORWARD_OR_CROSS) {} }
	assert_raises(ArgumentError) { graph.each_bfs(v1, Graph::BACK) {} }
    end

    def assert_dfs_trace(branches, graph, enum, root, filter, check_kind = true)
	branches = branches.map do |b|
	    b.find_all { |e| e[3] & filter != 0 }
	end
	trace = graph.enum_for(enum, root, filter).to_a
	if !check_kind
	    trace.map! { |edge| edge[0..-2] }
	end

	begin
	    assert( branches.find { |b| b == trace } ) #, trace )
	rescue 
	    #pp trace
	    raise
	end
    end

    def setup_test_graph(reverse)
	graph = Graph.new

	vertices = (1..5).map { Vertex.new }
	v1, v2, v3, v4, v5 = *vertices
	vertices.each { |v| graph.insert(v) }

	links = [[v1, v2, 1],
	    [v2, v3, 2],
	    [v3, v4, 3],
	    [v4, v2, 4],
	    [v1, v5, 5],
	    [v5, v2, 6]]

	links.each do |edge|
	    if reverse
		edge[0], edge[1] = edge[1], edge[0]
	    end
	    graph.link(*edge)
	end

	[graph, vertices]
    end

    def test_linked_p
	graph, vertices = setup_test_graph(false)
	v1, v2, v3, v4, v5 = *vertices
	assert( graph.linked?(v1, v2) )
	assert( graph.linked?(v2, v3) )
	assert( graph.linked?(v3, v4) )
	assert( graph.linked?(v4, v2) )
	assert( graph.linked?(v1, v5) )
	assert( graph.linked?(v5, v2) )
	assert( !graph.linked?(v2, v1) )
	assert( !graph.linked?(v3, v2) )
	assert( !graph.linked?(v4, v3) )
	assert( !graph.linked?(v2, v4) )
	assert( !graph.linked?(v5, v1) )
	assert( !graph.linked?(v2, v5) )
    end

    def check_dfs(graph, vertices)
	v1, v2, v3, v4, v5 = *vertices

	traces = []
	traces << [
	    [v1, v5, 5, Graph::TREE], 
	    [v5, v2, 6, Graph::TREE],
	    [v2, v3, 2, Graph::TREE], 
	    [v3, v4, 3, Graph::TREE], 
	    [v4, v2, 4, Graph::BACK],
	    [v1, v2, 1, Graph::FORWARD_OR_CROSS]
	]
	traces << [
	    [v1, v2, 1, Graph::TREE], 
	    [v2, v3, 2, Graph::TREE], 
	    [v3, v4, 3, Graph::TREE], 
	    [v4, v2, 4, Graph::BACK],
	    [v1, v5, 5, Graph::TREE], 
	    [v5, v2, 6, Graph::FORWARD_OR_CROSS]
	]
	assert_dfs_trace(traces, graph, :each_dfs, v1, Graph::ALL)
	assert_dfs_trace(traces, graph, :each_dfs, v1, Graph::TREE)
	assert_dfs_trace(traces, graph, :each_dfs, v1, Graph::FORWARD_OR_CROSS)
	assert_dfs_trace(traces, graph, :each_dfs, v1, Graph::BACK)
    end

    def test_each_dfs
	# v1---->v2-->v3-->v4
	# |       ^---------|
	# |-->v5--^     
	graph, vertices = setup_test_graph(false)
	check_dfs(graph, vertices)
    end
    def test_reverse_each_dfs
	# Build a graph so that doing #each_dfs on #reverse should yield the same result
	# than in test_each_dfs
	graph, vertices = setup_test_graph(true)
	check_dfs(graph.reverse, vertices)
    end

    def test_dfs_prune
	graph = Graph.new
	vertices = (1..5).map { Vertex.new }
	v1, v2, v3 = *vertices
	vertices.each { |v| graph.insert(v) }

	graph.link v1, v2, 1
	graph.link v2, v3, 2
	graph.link v1, v3, 1

	FlexMock.use do |mock|
	    mock.should_receive(:found).with(v1, v2).once
	    mock.should_receive(:found).with(v1, v3).once
	    graph.each_dfs(v1, Graph::ALL) do |s, t, _, _| 
		mock.found(s, t) 
		graph.prune
	    end
	end
    end

    #def test_undirected_dfs
    #    # v1---->v2-->v3-->v4
    #    # |       ^---------|
    #    # |-->v5--^     
    #    graph, vertices = setup_test_graph(false)
    #    v1, v2, v3, v4, v5 = *vertices
    #    
    #    # Do instead
    #    # v1---->v2
    #    # |       ^
    #    # |-->v5--^     
    #    graph.unlink(v2, v3)
    #    graph.unlink(v4, v2)

    #    traces = []
    #    traces << [ [v1, v2, 1], [v2, v5, 6], [v5, v1, 5] ]
    #    traces << [ [v1, v5, 5], [v5, v2, 6], [v2, v1, 1] ]
    #    assert_dfs_trace(traces, graph.undirected, :each_dfs, v2, Graph::ALL, false)
    #end

    def test_topological_sort
	graph, (v1, v2, v3, v4) = setup_graph(4)
	graph.link v1, v2, nil
	graph.link v2, v3, nil
	graph.link v1, v3, nil
	graph.link v3, v4, nil

	sort = graph.topological_sort
	assert_equal([v1, v2, v3, v4], sort)

	sort = [v3, v4, v2]
	graph.topological_sort(sort)
	assert_equal([v1, v2, v3, v4], sort)

	graph.link(v4, v1, nil)
	assert_raises(ArgumentError) { graph.topological_sort }
    end

    def test_neighborhood
	# v1---->v2-->v3-->v4
	# |       ^---------|
	# |-->v5--^     
	graph, vertices = setup_test_graph(false)
	v1, v2, v3, v4, v5 = *vertices

	neigh1 = [[v1, v2, 1], [v1, v5, 5]]
	assert_equal(neigh1.to_set, graph.neighborhood(v1, 1).to_set)
	neigh2 = neigh1 + [[v4, v2, 4], [v2, v3, 2], [v5, v2, 6]]
	assert_equal(neigh2.to_set, graph.neighborhood(v1, 2).to_set)
	neigh3 = neigh2 + [[v3, v4, 3]]
	assert_equal(neigh3.to_set, graph.neighborhood(v1, 3).to_set)
    end

    def test_vertex_singleton
	v1, v2, v3 = (1..3).map { Vertex.new }
	g1, g2 = Graph.new, Graph.new

	assert(v1.singleton_vertex?)
	assert(v2.singleton_vertex?)
	assert(v3.singleton_vertex?)
	g1.link(v1, v2, nil)
	assert(!v1.singleton_vertex?)
	assert(!v2.singleton_vertex?)
	assert(v3.singleton_vertex?)
	g2.link(v1, v3, nil)
	assert(!v3.singleton_vertex?)

	g1.unlink(v1, v2)
	assert(!v1.singleton_vertex?)
	assert(v2.singleton_vertex?)
	g1.link(v1, v3, nil)
	g2.unlink(v1, v3)
	assert(!v1.singleton_vertex?)
	assert(!v3.singleton_vertex?)
	g1.unlink(v1, v3)
	assert(v1.singleton_vertex?)
	assert(v3.singleton_vertex?)
    end

    def test_graph_reachable
	v1, v2, v3 = (1..3).map { Vertex.new }
	g = Graph.new
	assert(!g.reachable?(v1, v3))
	g.link v1, v2, nil
	assert(!g.reachable?(v1, v3))
	g.link v2, v3, nil
	assert(g.reachable?(v1, v2))
	assert(g.reachable?(v1, v3))
	assert(!g.reachable?(v3, v1))
	assert(!g.reachable?(v2, v1))

	g.link(v3, v1, nil)
	assert(g.reachable?(v2, v1))
	assert(g.reachable?(v3, v1))
    end

    def test_difference
        v_a = (1..3).map { Vertex.new }
        v_b = (1..3).map { Vertex.new }
        mapping = Hash.new
        v_a.each_with_index do |v, i|
            mapping[v] = v_b[i]
        end
	a = Graph.new
	b = Graph.new

        assert_equal([Set.new, Set.new, Set.new], a.difference(b, v_a, &mapping.method(:[])))

        a.link(v_a[0], v_a[1], nil)
        assert_equal([[[v_a[0], v_a[1]]].to_set, Set.new, Set.new], a.difference(b, v_a, &mapping.method(:[])))

        b.link(v_b[0], v_b[1], nil)
        assert_equal([Set.new, Set.new, Set.new], a.difference(b, v_a, &mapping.method(:[])))

        b.link(v_b[0], v_b[2], nil)
        b.link(v_b[2], v_b[1], nil)
        assert_equal([Set.new, [[v_b[0], v_b[2]], [v_b[2], v_b[1]]].to_set, Set.new], a.difference(b, v_a, &mapping.method(:[])))

        a.link(v_a[2], v_a[1], [])
        assert_equal([Set.new, [[v_b[0], v_b[2]]].to_set, [[v_a[2], v_a[1]]].to_set], a.difference(b, v_a, &mapping.method(:[])))
    end
end

