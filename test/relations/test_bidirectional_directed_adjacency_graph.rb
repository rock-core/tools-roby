# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Relations
        describe BidirectionalDirectedAdjacencyGraph do
            include RGL
            include RGL::Edge

            def assert_is_consistent(graph)
                graph.verify_consistency
            end

            def create_graph(*initial)
                g = BidirectionalDirectedAdjacencyGraph[*initial]
                @created_graphs << g
                g
            end

            def setup
                @created_graphs = []
                super
            end

            def teardown
                super
                @created_graphs.each do |g|
                    assert_is_consistent g
                end
            end

            def test_empty_graph
                dg = create_graph
                assert dg.empty?
                assert dg.directed?
                assert(!dg.has_edge?(2, 1))
                assert(!dg.has_vertex?(3))
                assert_equal [], dg.each_out_neighbour(3).to_a
                assert_equal 0, dg.out_degree(3)
                assert_equal [], dg.each_in_neighbour(3).to_a
                assert_equal 0, dg.in_degree(3)
                assert_equal([], dg.vertices)
                assert_equal(0, dg.size)
                assert_equal(0, dg.num_vertices)
                assert_equal(0, dg.num_edges)
                assert_equal(BidirectionalDirectedAdjacencyGraph::DirectedEdge, dg.edge_class)
                assert([].eql?(dg.edges))
            end

            def test_add
                dg = create_graph
                dg.add_edge(1, 2)
                assert(!dg.empty?)
                assert(dg.has_edge?(1, 2))
                assert(!dg.has_edge?(2, 1))
                assert(dg.has_vertex?(1) && dg.has_vertex?(2))
                assert(!dg.has_vertex?(3))

                assert_equal([1, 2], dg.vertices.sort)
                assert([BidirectionalDirectedAdjacencyGraph::DirectedEdge.new(1, 2)].eql?(dg.edges))
                assert_equal("(1-2)", dg.edges.join)

                assert_equal([2], dg.adjacent_vertices(1).to_a)
                assert_equal([], dg.adjacent_vertices(2).to_a)

                assert_equal(1, dg.out_degree(1))
                assert_equal(0, dg.out_degree(2))
            end

            def test_add_with_info
                dg = create_graph
                dg.add_edge(1, 2, 3)
                assert_equal 3, dg.edge_info(1, 2)
            end

            def test_set_edge_info
                dg = create_graph
                dg.add_edge(1, 2, 3)
                dg.set_edge_info(1, 2, 42)
                assert_equal 42, dg.edge_info(1, 2)
            end

            def test_edges
                dg = create_graph
                [[1, 2], [2, 3], [3, 2], [2, 4]].each do |(src, target)|
                    dg.add_edge(src, target)
                end
                assert_equal(4, dg.edges.length)
                assert_equal([1, 2, 2, 3], dg.edges.map(&:source).sort)
                assert_equal([2, 2, 3, 4], dg.edges.map(&:target).sort)
                assert_equal("(1-2)(2-3)(2-4)(3-2)", dg.edges.map(&:to_s).sort.join)
                #    assert_equal([0,1,2,3], dg.edges.map {|l| l.info}.sort)
            end

            def test_vertices
                dg = create_graph
                [[1, 2], [2, 3], [3, 2], [2, 4]].each do |(src, target)|
                    dg.add_edge(src, target)
                end
                assert_equal([1, 2, 3, 4], dg.vertices.sort)
            end

            def test_edges_from_to?
                dg = create_graph
                [[1, 2], [2, 3], [3, 2], [2, 4]].each do |(src, target)|
                    dg.add_edge(src, target)
                end
                assert dg.has_edge?(1, 2)
                assert dg.has_edge?(2, 3)
                assert dg.has_edge?(3, 2)
                assert dg.has_edge?(2, 4)
                assert !dg.has_edge?(2, 1)
                assert !dg.has_edge?(3, 1)
                assert !dg.has_edge?(4, 1)
                assert !dg.has_edge?(4, 2)
            end

            def test_remove_edges
                dg = create_graph
                [[1, 2], [2, 3], [3, 2], [2, 4]].each do |(src, target)|
                    dg.add_edge(src, target)
                end
                dg.remove_edge 1, 2
                assert !dg.has_edge?(1, 2)
                dg.remove_edge 1, 2
                assert !dg.has_edge?(1, 2)
                dg.remove_vertex 3
                assert !dg.has_vertex?(3)
                assert !dg.has_edge?(2, 3)
                assert_equal("(2-4)", dg.edges.join)
            end

            def test_add_vertices
                dg = create_graph
                dg.add_vertices 1, 3, 2, 4
                assert_equal dg.vertices.sort, [1, 2, 3, 4]

                dg.remove_vertices 1, 3
                assert_equal dg.vertices.sort, [2, 4]
            end

            def test_creating_from_array
                dg = BidirectionalDirectedAdjacencyGraph[1, 2, 3, 4]
                assert_equal([1, 2, 3, 4], dg.vertices.sort)
                assert_equal("(1-2)(3-4)", dg.edges.join)
            end

            def test_reverse
                dg = create_graph
                [[1, 2], [2, 3], [3, 2], [2, 4]].each do |(src, target)|
                    dg.add_edge(src, target, [src])
                end
                # Add isolated vertex
                dg.add_vertex(42)
                reverted = dg.reverse

                dg.each_edge do |u, v|
                    assert(reverted.has_edge?(v, u))
                    assert_equal [u], reverted.edge_info(v, u)
                end

                assert(reverted.has_vertex?(42), "Reverted graph should contain isolated Vertex 42")
            end

            def test_dup
                edge_info = Struct.new :value
                dg = create_graph
                dg.add_edge(1, 2, edge_info.new(12))
                dg.add_edge(2, 3, edge_info.new(23))
                dg.add_edge(1, 3, edge_info.new(13))
                dg.add_edge(3, 4, edge_info.new(34))
                dg.add_edge(3, 5, edge_info.new(35))
                copy = dg.dup
                assert_equal dg.each_edge.to_a,
                             copy.each_edge.to_a
            end

            def test_move_edges
                dg = create_graph
                dg.add_edge(1, 2, 12)
                dg.add_edge(2, 3, 23)
                dg.add_edge(1, 3, 13)
                dg.add_edge(3, 4, 34)
                dg.add_edge(3, 5, 35)

                dg.move_edges(3, 10)
                assert_is_consistent dg

                expected_edges =
                    Set[[1, 2, 12],
                        [2, 10, 23],
                        [1, 10, 13],
                        [10, 4, 34],
                        [10, 5, 35]]
                assert_equal expected_edges, dg.each_edge.to_set
            end

            describe "#difference" do
                attr_reader :a, :b, :v_a, :v_b, :mapping
                before do
                    @v_a = (1..3).map { Object.new }
                    @v_b = (1..3).map { Object.new }
                    @mapping = {}
                    v_a.each_with_index do |v, i|
                        mapping[v] = v_b[i]
                    end
                    @a = create_graph
                    @b = create_graph
                end

                it "returns empty sets for empty graphs" do
                    assert_equal([[], [], []],
                                 a.difference(b, v_a, &mapping.method(:[])))
                end

                it "reports an edge in the receiver and not in the argument as new" do
                    a.add_edge(v_a[0], v_a[1], nil)
                    assert_equal([[[v_a[0], v_a[1]]], [], []],
                                 a.difference(b, v_a, &mapping.method(:[])))
                end

                it "does not report a common edge" do
                    a.add_edge(v_a[0], v_a[1], nil)
                    b.add_edge(v_b[0], v_b[1], nil)
                    assert_equal([[], [], []],
                                 a.difference(b, v_a, &mapping.method(:[])))
                end

                it "reports edges in the argument not in the receiver as removed" do
                    b.add_edge(v_b[0], v_b[2], nil)
                    b.add_edge(v_b[2], v_b[1], nil)
                    assert_equal([[], [[v_b[0], v_b[2]], [v_b[2], v_b[1]]], []],
                                 a.difference(b, v_a, &mapping.method(:[])))
                end

                it "reports an edge whose info has changed as updated" do
                    b.add_edge(v_b[2], v_b[1], nil)
                    a.add_edge(v_a[2], v_a[1], [])
                    assert_equal([[], [], [[v_a[2], v_a[1]]]],
                                 a.difference(b, v_a, &mapping.method(:[])))
                end
            end

            describe "#to_a" do
                it "returns the list of vertices" do
                    dg = create_graph(1, 2, 2, 3, 3, 2, 2, 4)
                    assert_equal [1, 2, 3, 4], dg.to_a
                end
            end

            describe "#out_degree" do
                it "returns the number of out-edges of a vertex" do
                    dg = create_graph(1, 2, 2, 3, 2, 4)
                    assert_equal 1, dg.out_degree(1)
                    assert_equal 2, dg.out_degree(2)
                    assert_equal 0, dg.out_degree(3)
                end
                it "returns zero for a vertex not in the graph" do
                    dg = create_graph
                    assert_equal 0, dg.out_degree(2)
                end
            end

            describe "#root?" do
                it "returns true for vertices that have no out-edges" do
                    dg = create_graph(1, 2)
                    assert dg.root?(1)
                end
                it "returns false for vertices that have out-edges" do
                    dg = create_graph(1, 2)
                    refute dg.root?(2)
                end
            end

            describe "#in_degree" do
                it "returns the number of in-edges of a vertex" do
                    dg = create_graph(1, 3, 2, 3, 3, 4)
                    assert_equal 2, dg.in_degree(3)
                    assert_equal 0, dg.in_degree(1)
                    assert_equal 1, dg.in_degree(4)
                end
                it "returns zero for a vertex not in the graph" do
                    dg = create_graph
                    assert_equal 0, dg.in_degree(2)
                end
            end

            describe "#leaf?" do
                it "returns true for vertices that have no in-edges" do
                    dg = create_graph(1, 2)
                    assert dg.leaf?(2)
                end
                it "returns false for vertices that have in-edges" do
                    dg = create_graph(1, 2)
                    refute dg.leaf?(1)
                end
            end

            describe "#replace" do
                attr_reader :new, :old
                before do
                    @new = create_graph
                    @old = create_graph(1, 2, 1, 3, 3, 4)
                end
                it "replaces the internal structure by the the one from its argument" do
                    expected = old.dup
                    new.replace(old)
                    assert new.same_structure?(expected)
                end
                it "does not touch its argument" do
                    new.replace(old)
                    refute old.empty?
                end
            end

            describe "#add_edge" do
                attr_reader :graph, :parent, :child
                before do
                    @graph = create_graph
                    @parent = Object.new
                    @child  = Object.new
                end
                it "raises if trying to register a self-referencing edge" do
                    e = assert_raises(ArgumentError) do
                        graph.add_edge(parent, parent, nil)
                    end
                    assert_equal "cannot add self-referencing edges", e.message
                end
                it "registers the edge" do
                    graph.add_edge(parent, child, nil)
                    assert graph.has_edge?(parent, child)
                end
                it "registers the info object" do
                    graph.add_edge(parent, child, info = Object.new)
                    assert_same info, graph.edge_info(parent, child)
                end
                it "registers the out-edge" do
                    graph.add_edge(parent, child, nil)
                    assert graph.out_neighbours(parent).include?(child)
                end
                it "registers the in-edge" do
                    graph.add_edge(parent, child, nil)
                    assert graph.in_neighbours(child).include?(parent)
                end
            end

            describe "#remove_vertex" do
                attr_reader :graph, :obj
                before do
                    @graph = create_graph
                    @obj   = Object.new
                end
                it "removes vertex out-edges and returns true" do
                    graph.add_edge(obj, child = Object.new, nil)
                    assert graph.remove_vertex(obj)
                    refute graph.has_edge?(obj, child)
                end
                it "removes vertex in-edges and returns true" do
                    graph.add_edge(parent = Object.new, obj, nil)
                    assert graph.remove_vertex(obj)
                    refute graph.has_edge?(parent, obj)
                end
                it "returns false if the vertex was in the graph but had no edges" do
                    graph.add_vertex(obj)
                    refute graph.remove_vertex(obj)
                end
                it "ignores a vertex that is not in the graph" do
                    refute graph.remove_vertex(obj)
                end
            end

            describe "#num_vertices" do
                it "returns zero for an empty graph" do
                    assert_equal 0, create_graph.num_vertices
                end
                it "returns the total number of vertices in the graph" do
                    dg = create_graph(1, 2, 3, 4)
                    assert_equal 4, dg.num_vertices
                end
            end

            describe "#num_edges" do
                it "returns zero for an empty graph" do
                    assert_equal 0, create_graph.num_edges
                end
                it "returns the total number of edges in the graph" do
                    dg = create_graph(1, 2, 3, 4)
                    assert_equal 2, dg.num_edges
                end
            end

            describe "#edge_info" do
                it "returns the info of an existing edge" do
                    graph = create_graph
                    graph.add_edge(10, 20, info = Object.new)
                    assert_equal info, graph.edge_info(10, 20)
                end
                it "raises if the parent is not in the graph" do
                    graph = create_graph(20, 30)
                    e = assert_raises(ArgumentError) do
                        graph.edge_info(10, 20)
                    end
                    assert_equal "no edge 10 => 20 in #{graph}", e.message
                end
                it "raises if the child is not in the graph" do
                    graph = create_graph(10, 30)
                    e = assert_raises(ArgumentError) do
                        graph.edge_info(10, 20)
                    end
                    assert_equal "no edge 10 => 20 in #{graph}", e.message
                end
                it "raises if the edge does not exist" do
                    graph = create_graph(10, 30, 20, 30)
                    e = assert_raises(ArgumentError) do
                        graph.edge_info(10, 20)
                    end
                    assert_equal "no edge 10 => 20 in #{graph}", e.message
                end
            end

            describe "#set_edge_info" do
                it "sets the info of an existing edge" do
                    graph = create_graph(10, 20)
                    graph.set_edge_info(10, 20, info = Object.new)
                    assert_equal info, graph.edge_info(10, 20)
                end
                it "raises if the parent is not in the graph" do
                    graph = create_graph(20, 30)
                    e = assert_raises(ArgumentError) do
                        graph.set_edge_info(10, 20, nil)
                    end
                    assert_equal "no edge 10 => 20 in #{graph}", e.message
                end
                it "raises if the child is not in the graph" do
                    graph = create_graph(10, 30)
                    e = assert_raises(ArgumentError) do
                        graph.set_edge_info(10, 20, nil)
                    end
                    assert_equal "no edge 10 => 20 in #{graph}", e.message
                end
                it "raises if the edge does not exist" do
                    graph = create_graph(10, 30, 20, 30)
                    e = assert_raises(ArgumentError) do
                        graph.set_edge_info(10, 20, nil)
                    end
                    assert_equal "no edge 10 => 20 in #{graph}", e.message
                end
            end

            describe "#merge" do
                attr_reader :receiver, :argument
                before do
                    @receiver = create_graph(1, 2, 2, 3, 2, 4)
                    @argument = create_graph(0, 2, 2, 3, 2, 5, 6, 7)
                end
                it "adds all forward edges to the receiver" do
                    receiver.merge(argument)
                    assert_equal [[0, 2, nil], [1, 2, nil], [2, 3, nil], [2, 4, nil], [2, 5, nil], [6, 7, nil]].sort,
                                 receiver.each_edge.to_a.sort
                end
                it "does not modify the argument" do
                    receiver.merge(argument)
                    assert_equal [[0, 2, nil], [2, 3, nil], [2, 5, nil], [6, 7, nil]].sort,
                                 argument.each_edge.to_a.sort
                end
                it "ensures that the receiver and argument have separate out and in-edge sets" do
                    receiver.merge(argument)
                    argument.add_edge(2, 42)
                    receiver.add_edge(84, 2)
                    refute receiver.has_edge?(2, 42)
                    refute argument.has_edge?(84, 2)
                end
                it "copies the edge info of new edges" do
                    argument.set_edge_info(2, 5, info = Object.new)
                    receiver.merge(argument)
                    assert_equal info, receiver.edge_info(2, 5)
                end
                it "update the edge info of existing edges" do
                    receiver.set_edge_info(2, 3, old_info = Object.new)
                    argument.set_edge_info(2, 3, info = Object.new)
                    receiver.merge(argument)
                    assert_equal info, receiver.edge_info(2, 3)
                end
            end

            describe "#verify_consistency" do
                it "passes for an empty graph" do
                    create_graph.verify_consistency
                end
                it "passes for a valid graph" do
                    create_graph(1, 2, 2, 3, 5, 6).verify_consistency
                end
                it "raises if a vertex is registered in the forward edges but not in the backward edges" do
                    g = BidirectionalDirectedAdjacencyGraph.new
                    g.add_vertex(10)
                    g.backward_edges.delete(10)
                    assert_raises(BidirectionalDirectedAdjacencyGraph::Inconsistent) do
                        g.verify_consistency
                    end
                end
                it "raises if a vertex is registered in the backward edges but not in the forward edges" do
                    g = BidirectionalDirectedAdjacencyGraph.new
                    g.add_vertex(10)
                    g.forward_edges_with_info.delete(10)
                    assert_raises(BidirectionalDirectedAdjacencyGraph::Inconsistent) do
                        g.verify_consistency
                    end
                end
                it "raises if a forward edge exists without the corresponding backward edge" do
                    g = BidirectionalDirectedAdjacencyGraph[1, 2]
                    g.backward_edges[2].clear
                    assert_raises(BidirectionalDirectedAdjacencyGraph::Inconsistent) do
                        g.verify_consistency
                    end
                end
                it "raises if a forward edge exists and the edge's sink is not even in the graph" do
                    g = BidirectionalDirectedAdjacencyGraph[1, 2]
                    g.forward_edges_with_info.delete(2)
                    g.backward_edges.delete(2)
                    assert_raises(BidirectionalDirectedAdjacencyGraph::Inconsistent) do
                        g.verify_consistency
                    end
                end
                it "raises if a backward edge exists without the corresponding forward edge" do
                    g = BidirectionalDirectedAdjacencyGraph[1, 2]
                    g.forward_edges_with_info[1].clear
                    assert_raises(BidirectionalDirectedAdjacencyGraph::Inconsistent) do
                        g.verify_consistency
                    end
                end
                it "raises if a backward edge exists and the edge's source is not even in the graph" do
                    g = BidirectionalDirectedAdjacencyGraph[1, 2]
                    g.forward_edges_with_info.delete(1)
                    g.backward_edges.delete(1)
                    assert_raises(BidirectionalDirectedAdjacencyGraph::Inconsistent) do
                        g.verify_consistency
                    end
                end
            end
        end
    end
end
