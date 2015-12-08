require 'roby/test/self'

module Roby
    module Relations

        class TestBidirectionalDirectedAdjacencyGraph < Minitest::Test
            include RGL
            include RGL::Edge

            def graph_class; BidirectionalDirectedAdjacencyGraph end

            def setup
                @dg = graph_class.new
                [[1, 2], [2, 3], [3, 2], [2, 4]].each do |(src, target)|
                    @dg.add_edge(src, target)
                end
                super
            end

            def test_empty_graph
                dg = graph_class.new
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
                assert_equal(DirectedEdge, dg.edge_class)
                assert([].eql?(dg.edges))
            end

            def test_add
                dg = graph_class.new
                dg.add_edge(1, 2)
                assert(!dg.empty?)
                assert(dg.has_edge?(1, 2))
                assert(!dg.has_edge?(2, 1))
                assert(dg.has_vertex?(1) && dg.has_vertex?(2))
                assert(!dg.has_vertex?(3))

                assert_equal([1, 2], dg.vertices.sort)
                assert([DirectedEdge.new(1, 2)].eql?(dg.edges))
                assert_equal("(1-2)", dg.edges.join)

                assert_equal([2], dg.adjacent_vertices(1).to_a)
                assert_equal([], dg.adjacent_vertices(2).to_a)

                assert_equal(1, dg.out_degree(1))
                assert_equal(0, dg.out_degree(2))
            end

            def test_add_with_info
                dg = graph_class.new
                dg.add_edge(1, 2, 3)
                assert_equal 3, dg.edge_info(1, 2)
            end

            def test_set_edge_info
                dg = graph_class.new
                dg.add_edge(1, 2, 3)
                dg.set_edge_info(1, 2, 42)
                assert_equal 42, dg.edge_info(1, 2)
            end

            def test_edges
                assert_equal(4, @dg.edges.length)
                assert_equal([1, 2, 2, 3], @dg.edges.map { |l| l.source }.sort)
                assert_equal([2, 2, 3, 4], @dg.edges.map { |l| l.target }.sort)
                assert_equal("(1-2)(2-3)(2-4)(3-2)", @dg.edges.map { |l| l.to_s }.sort.join)
                #    assert_equal([0,1,2,3], @dg.edges.map {|l| l.info}.sort)
            end

            def test_vertices
                assert_equal([1, 2, 3, 4], @dg.vertices.sort)
            end

            def test_edges_from_to?
                assert @dg.has_edge?(1, 2)
                assert @dg.has_edge?(2, 3)
                assert @dg.has_edge?(3, 2)
                assert @dg.has_edge?(2, 4)
                assert !@dg.has_edge?(2, 1)
                assert !@dg.has_edge?(3, 1)
                assert !@dg.has_edge?(4, 1)
                assert !@dg.has_edge?(4, 2)
            end

            def test_remove_edges
                @dg.remove_edge 1, 2
                assert !@dg.has_edge?(1, 2)
                @dg.remove_edge 1, 2
                assert !@dg.has_edge?(1, 2)
                @dg.remove_vertex 3
                assert !@dg.has_vertex?(3)
                assert !@dg.has_edge?(2, 3)
                assert_equal('(2-4)', @dg.edges.join)
            end

            def test_add_vertices
                dg = graph_class.new
                dg.add_vertices 1, 3, 2, 4
                assert_equal dg.vertices.sort, [1, 2, 3, 4]

                dg.remove_vertices 1, 3
                assert_equal dg.vertices.sort, [2, 4]
            end

            def test_creating_from_array
                dg = graph_class[1, 2, 3, 4]
                assert_equal([1, 2, 3, 4], dg.vertices.sort)
                assert_equal('(1-2)(3-4)', dg.edges.join)
            end

            def test_reverse
                # Add isolated vertex
                @dg.add_vertex(42)
                reverted = @dg.reverse

                @dg.each_edge do |u, v|
                    assert(reverted.has_edge?(v, u))
                end

                assert(reverted.has_vertex?(42), 'Reverted graph should contain isolated Vertex 42')
            end

            def test_dup
                edge_info = Struct.new :value
                dg = graph_class.new
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
                dg = graph_class.new
                dg.add_edge(1, 2, 12)
                dg.add_edge(2, 3, 23)
                dg.add_edge(1, 3, 13)
                dg.add_edge(3, 4, 34)
                dg.add_edge(3, 5, 35)

                dg.move_edges(3, 10)
                expected_edges =
                    Set[[1, 2, 12],
                        [2, 10, 23],
                        [1, 10, 13],
                        [10, 4, 34],
                        [10, 5, 35]]
                assert_equal expected_edges, dg.each_edge.to_set
            end
        end
    end
end


