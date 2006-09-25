$LOAD_PATH.unshift File.join(File.expand_path(File.dirname(__FILE__)), '../lib')
require 'test/unit'
require 'roby/graph'
require 'enumerator'
require 'set'

class TC_BGL < Test::Unit::TestCase
    include BGL
    def test_vertices_descriptors
	g = Graph.new
	v1 = g.add_vertex(d1 = 'a')
	v2 = g.add_vertex(d2 = 'b')
	assert_equal([d1, d2].to_set, g.enum_for(:each_vertex).to_set)
	assert_equal(d1, g.vertex_data(v1))

	g.remove_vertex(v1)
	assert_equal([d2].to_set, g.enum_for(:each_vertex).to_set)

	v3 = g.add_vertex(d3 = 'c')
	assert_equal([d2, d3].to_set, g.enum_for(:each_vertex).to_set)
    end

    def test_edges_descriptors
	g = Graph.new
	v1 = g.add_vertex(d1 = 'a')
	v2 = g.add_vertex(d2 = 'b')

	g.add_edge(v1, v2, 'bla')
	assert_equal('bla', g.edge_data(v1, v2))
	assert_raises(ArgumentError) { g.add_edge(v1, v2, nil) }
	assert_raises(ArgumentError) { g.edge_data(v2, v1) }
	assert_equal([[d1, d2, 'bla']], g.enum_for(:each_edge).to_a)

	g.remove_edge(v1, v2)
	assert_raises(ArgumentError) { g.edge_data(v1, v2) }
	assert_equal([], g.enum_for(:each_edge).to_a)

	g.add_edge(v2, v1, 'foo')
	assert_equal('foo', g.edge_data(v2, v1))
	assert_equal([[d2, d1, 'foo']], g.enum_for(:each_edge).to_a)
    end
    
    def test_vertex_objects
	graph = Graph.new
	klass = Class.new { include Vertex }

	v1 = klass.new
	graph.insert v1
	assert(graph.include?(v1))
	assert_equal([v1], graph.enum_for(:each_vertex).to_a)
	assert_equal([graph], v1.enum_for(:each_graph).to_a)

	graph.remove v1
	assert(!graph.include?(v1))
	assert_equal([], graph.enum_for(:each_vertex).to_a)
	assert_equal([], v1.enum_for(:each_graph).to_a)

	g1, g2 = Graph.new, Graph.new
	g1.insert(v1)
	g2.insert(v1)
	v1.clear_vertex
	assert(!g1.include?(v1))
	assert(!g2.include?(v1))
    end

    def test_replace
	graph = Graph.new
	klass = Class.new { include Vertex }

	v1, v2, v3 = (1..3).map { klass.new }
	graph.link(v1, v2, 1)
	graph.link(v2, v3, 2)

	v4 = klass.new
	graph.replace_vertex(v2, v4)
	assert(! graph.linked?(v1, v2))
	assert(! graph.linked?(v2, v3))
	assert_equal(1, v1[v4, graph])
	assert_equal(2, v4[v3, graph])
    end

    def test_edge_objects
	g1, g2 = Graph.new, Graph.new
	klass = Class.new { include Vertex }

	v1, v2, v3 = klass.new, klass.new, klass.new
	g1.link v1, v2, 1
	assert(g1.include?(v1))
	assert(g1.include?(v2))
	assert(g1.linked?(v1, v2))
	assert(!g1.linked?(v2, v1))

	g2.link v3, v2, 2
	assert_raises(ArgumentError) { g2.link v3, v2, 2 }
	assert_equal(2, v3[v2, g2])

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

    def test_end_predicates
	g1, g2 = Graph.new, Graph.new
	klass = Class.new { include Vertex }

	v1, v2, v3, v4 = klass.new, klass.new, klass.new, klass.new
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
	assert_equal(expected.size, found.size)
	# Equality of set-of-set does not work, don't know why
	assert_equal(expected.map { |c| c.sort_by { |e| e.object_id } }.to_set, 
		     found.map { |c| c.sort_by { |e| e.object_id } }.to_set)
    end

    def test_graph_components
	graph = Graph.new
	klass = Class.new { include Vertex }

	vertices = (1..4).map { klass.new }
	v1, v2, v3, v4 = *vertices
	vertices.each { |v| graph.insert(v) }

	graph.link v1, v2, nil
	assert_components([[v1, v2], [v3], [v4]], graph.components)
	assert_components([[v1, v2]], graph.components(v1))
	assert_components([[v2]], graph.directed_components(v2))
	assert_components([[v1, v2]], graph.reverse_directed_components(v2))
	assert_components([[v4]], graph.components(v4))

	graph.link v4, v3, nil
	assert_components([[v1, v2], [v3, v4]], graph.components)
	assert_components([[v2], [v3]], graph.directed_components(v2, v3))
	assert_components([[v1, v2], [v4, v3]], graph.reverse_directed_components(v2, v3))
	assert_components([[v3, v4]], graph.directed_components(v4))

	graph.link v1, v3, nil
	assert_components([[v1, v2, v3, v4]], graph.components)
	assert_components([[v1, v2, v3, v4]], graph.components(v1))

	g2 = Graph.new
	graph.unlink v4, v3
	g2.link v4, v3, nil
	assert_components([[v4]], graph.components(v4))
	assert_components([[v4, v3]], g2.components(v3))

	v5 = klass.new
	# Check that we get a singleton component even if v5 is not in the graph
	assert_components([[v5]], graph.components(v5))
    end

    def test_vertex_component
	graph = Graph.new
	klass = Class.new { include Vertex }

	vertices = (1..4).map { klass.new }
	v1, v2, v3, v4 = *vertices
	vertices.each { |v| graph.insert(v) }

	graph.link v1, v2, nil
	graph.link v3, v2, nil
	graph.link v3, v4, nil
	graph.link v2, v4, nil
	assert_components([[v1, v2, v3, v4]], graph.components(v1))
	assert_components([[v1, v2, v3, v4]], graph.components(v2))

	g2 = Graph.new
	g2.link v4, v3, nil
	assert_components([[v4, v3]], g2.components(v4))
    end
end

