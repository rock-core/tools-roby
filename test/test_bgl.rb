$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/self'
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

    def test_unlink_does_nothing_when_none_of_the_arguments_are_included_in_the_graph
	v1, v2 = (1..2).map { Vertex.new }
	g = Graph.new
        g.unlink(v1, v2)
    end

    def test_unlink_does_nothing_when_only_the_sink_is_included_in_the_graph
	v1, v2 = (1..2).map { Vertex.new }
	g = Graph.new
        g.insert(v2)
        g.unlink(v1, v2)
    end

    def test_unlink_does_nothing_when_only_the_source_is_included_in_the_graph
	v1, v2 = (1..2).map { Vertex.new }
	g = Graph.new
        g.insert(v1)
        g.unlink(v1, v2)
    end

    def test_unlink_does_nothing_when_it_is_called_with_two_vertices_included_in_the_graph_that_have_no_edge
	v1, v2 = (1..2).map { Vertex.new }
	g = Graph.new
        g.insert(v1)
        g.insert(v2)
        g.unlink(v1, v2)
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

describe BGL::Graph do
    attr_reader :graph, :vertex_m, :vertex
    before do
        @graph = BGL::Graph.new
        @vertex_m = Class.new do
            include BGL::Vertex
        end
        @vertex = @vertex_m.new
    end

    describe "#out_degree" do
        it "should return zero if the vertex is not included in the graph" do
            assert_equal 0, graph.out_degree(vertex)
        end
        it "should return zero if there are no out-edges for the vertex in the graph" do
            graph.insert(vertex)
            assert_equal 0, graph.out_degree(vertex)
        end
        it "should return the number of out-edges for the vertex in the graph" do
            graph.insert(vertex)
            a, b = vertex_m.new, vertex_m.new
            graph.insert(a)
            graph.insert(b)
            graph.link(vertex, a, nil)
            assert_equal 1, graph.out_degree(vertex)
            graph.link(vertex, b, nil)
            assert_equal 2, graph.out_degree(vertex)
            graph.link(b, vertex, nil)
            assert_equal 2, graph.out_degree(vertex)
        end
    end

    describe "#in_degree" do
        it "should return zero if the vertex is not included in the graph" do
            assert_equal 0, graph.in_degree(vertex)
        end
        it "should return zero if there are no in-edges for the vertex in the graph" do
            graph.insert(vertex)
            assert_equal 0, graph.in_degree(vertex)
        end
        it "should return the number of in-edges for the vertex in the graph" do
            graph.insert(vertex)
            a, b = vertex_m.new, vertex_m.new
            graph.insert(a)
            graph.insert(b)
            graph.link(a, vertex, nil)
            assert_equal 1, graph.in_degree(vertex)
            graph.link(b, vertex, nil)
            assert_equal 2, graph.in_degree(vertex)
            graph.link(vertex, b, nil)
            assert_equal 2, graph.in_degree(vertex)
        end
    end
end


describe BGL::Graph do
    attr_reader :graph, :vertex_m, :vertex, :visitor
    before do
        @graph = BGL::Graph.new
        @vertex_m = Class.new do
            include BGL::Vertex

            def self.id
                @counter += 1
            end
            @counter = 0

            def initialize(id = nil)
                @id = id || self.class.id
            end

            def to_s
                "V(#{@id})"
            end
        end
        @vertex = @vertex_m.new
        @visitor = flexmock
    end

    def create_and_add_vertices(count_or_names)
        if count_or_names.respond_to? :to_i
            count_or_names = (1..count_or_names)
        end
        count_or_names.map do |i|
            v = vertex_m.new(i)
            graph.insert(v)
            v
        end
    end

    def link(*vertices)
        vertices.each_cons(2) do |a, b|
            graph.link(a, b, nil)
        end
    end

    def should_visit(*expected)
        expected.each do |vertex, value|
            visitor.should_receive(:call).with(vertex, value).once
        end
    end

    describe "#prune" do
        it "should be reset if calling next from the iteration block" do
            a, b1, b2, c1, c2 = create_and_add_vertices %w{a b1 b2 c1 c2}
            link(a, b1)
            link(a, b2)

            pruned = false
            visited = []
            graph.each_dfs(a, BGL::Graph::ALL) do |from, to, info|
                visited << to
                if !pruned && [b1, b2].include?(to)
                    graph.prune
                    pruned = true
                    next
                end
            end

            assert(visited.include?(b1) && visited.include?(b2))
        end
    end

    describe "#fork_merge_propagation" do
        it "should handle singletons gracefully" do
            a = *create_and_add_vertices(1)
            value = flexmock
            should_visit([a, value])
            result = graph.fork_merge_propagation(a, value, :vertex_visitor => visitor)
            assert_equal Hash[a => value], result
        end

        it "should simply propagate when in a line" do
            a, b, c = create_and_add_vertices 3
            link(a, b, c)
            should_visit([a, 0], [b, 1], [c, 2])
            value = flexmock
            value.should_receive(:propagate).with(a, b, 0).and_return(1)
            value.should_receive(:propagate).with(b, c, 1).and_return(2)
            result = graph.fork_merge_propagation(a, 0, :vertex_visitor => visitor) do |from, to, v|
                value.propagate(from, to, v)
            end
            assert_equal Hash[c => 2], result
        end

        def setup_dfs(graph, *pairs)
            graph.singleton_class.class_eval do
                define_method :each_dfs do |*args, &block|
                    pairs.each(&block)
                end
            end
            graph
        end

        it "should fork when reaching a vertex that has more than one child" do
            a, b, c0, c1 = create_and_add_vertices 4
            link(a, b, c0)
            link(b, c1)

            v, v_clone = flexmock, flexmock
            v.should_receive(:fork).and_return(v_clone)
            should_visit([a, v], [b, v], [c0, v_clone], [c1, v_clone])
            setup_dfs graph, [a, b], [b, c0], [b, c1]
            result = graph.fork_merge_propagation(a, v, :vertex_visitor => visitor) do |from, to, v|
                v
            end
            assert_equal Hash[c0 => v_clone, c1 => v_clone], result
        end

        it "should merge forked branches" do
            a, b, c0, c1, d = create_and_add_vertices %w{a b c0 c1 d}
            link(a, b, c0, d)
            link(b, c1, d)

            v, v_clone, v_merged = flexmock, flexmock, flexmock
            v.should_receive(:propagate).with(a, b).once.and_return(v)
            v.should_receive(:fork).and_return(v_clone)
            v_clone.should_receive(:propagate).with(b, c0).once.and_return(v_clone)
            v_clone.should_receive(:propagate).with(c0, d).once.and_return(v_clone)
            v_clone.should_receive(:propagate).with(b, c1).once.and_return(v_clone)
            v_clone.should_receive(:propagate).with(c1, d).once.and_return(v_clone)
            v_clone.should_receive(:merge).once.with(v_clone).and_return(v_merged)
            should_visit([a, v], [b, v], [c0, v_clone], [c1, v_clone], [d, v_merged])
            setup_dfs graph, [a, b], [b, c0], [c0, d], [b, c1], [c1, d]
            flexmock(graph).should_receive(:prune).once
            result = graph.fork_merge_propagation(a, v, :vertex_visitor => visitor) do |from, to, v|
                v.propagate(from, to)
            end
            assert_equal Hash[d => v_merged], result
        end

        it "should propagate merges for which some inputs are not part of the interesting connected component" do
            a0, a1, b = create_and_add_vertices %w{a0 a1 b}
            link(a0, b)
            link(a1, b)

            v = flexmock
            v.should_receive(:propagate).and_return(v)
            should_visit([a0, v], [b, v])
            result = graph.fork_merge_propagation(a0, v, :vertex_visitor => visitor) do |from, to, v|
                v
            end
            assert_equal Hash[b => v], result
        end

        it "should allow the usage of #prune" do
            a, b0, b1, c = create_and_add_vertices %w{a b0 b1 c}
            link(a, b0, c)
            link(a, b1, c)

            v = flexmock
            v.should_receive(:propagate).and_return(v)
            v.should_receive(:fork).and_return(v)
            v.should_receive(:propagate).with(b1, c).never
            should_visit([a, v], [b0, v], [c, v])
            result = graph.fork_merge_propagation(a, v, :vertex_visitor => visitor) do |from, to, v|
                if to == b1
                    graph.prune
                else
                    v.propagate(from, to, v)
                end
            end
            assert_equal Hash[c, v], result
        end
        
        it "should allow to prune from the vertex visitor" do
            a, b0, b1, c = create_and_add_vertices %w{a b0 b1 c}
            link(a, b0, c)
            link(a, b1, c)

            v = flexmock
            v.should_receive(:propagate).and_return(v)
            v.should_receive(:fork).and_return(v)
            v.should_receive(:propagate).with(b1, c).never
            visitor.should_receive(:call).with(b1, v).and_return do
                graph.prune
            end
            should_visit([a, v], [b0, v], [c, v])
            result = graph.fork_merge_propagation(a, v, :vertex_visitor => visitor) do |from, to, v|
                v.propagate(from, to, v)
            end
            assert_equal Hash[c, v], result
        end
        
        it "should allow to prune from the vertex visitor at the seed level" do
            a, b = create_and_add_vertices %w{a b}
            link(a, b)

            v = flexmock
            v.should_receive(:propagate).never
            visitor.should_receive(:call).with(a, v).and_return do
                graph.prune
            end
            result = graph.fork_merge_propagation(a, v, :vertex_visitor => visitor) do |from, to, v|
                v.propagate(from, to, v)
            end
            assert_equal Hash[], result
        end

        it "does not add to the result the seeds that have been pruned" do
            a = *create_and_add_vertices(%w{a})
            v = flexmock
            visitor.should_receive(:call).with(a, v).and_return do
                graph.prune
            end
            result = graph.fork_merge_propagation(a, v, :vertex_visitor => visitor) do |from, to, v|
                v
            end
            assert result.empty?
        end

        it "allows pruning its seeds internally while still propagating the other branches" do
            # This is a corner case related to how the algorithm is implemented.
            # At some point, we catch the #pruned? flag without passing it to
            # the underlying iteration algorithm, so #fork_merge_propagation
            # must reset it manually. The symptom is that two branches are
            # pruned instead of one.
            #
            # It affects only the "internal" seeds, i.e. the merges vertices
            # that have parents outside the iterated graph
            a0, a1, a2, b, c0, c1, c2, d0, d1, d2 = create_and_add_vertices %w{a0 a1 a2 b c0 c1 c2 d0 d1 d2}
            link(a0, b, c0, d0)
            link(b, c1)
            link(b, c2)
            link(a1, c1, d1)
            link(a2, c2, d2)
            v = flexmock
            v.should_receive(:merge).and_return(v)
            v.should_receive(:fork).and_return(v)

            visited = []
            pruned = false
            visitor.should_receive(:call).and_return do |vertex, value|
                visited << vertex
                if [c1, c2].include?(vertex) && !pruned
                    pruned = true
                    graph.prune
                end
            end
            result = graph.fork_merge_propagation(a0, v, :vertex_visitor => visitor) do |from, to, v|
                v
            end

            assert(visited.include?(d1) ^ visited.include?(d2), "visited d1:#{visited.include?(d1)} d2:#{visited.include?(d2)}, should have visited at most one of the two")
        end
    end
end

