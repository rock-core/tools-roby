# frozen_string_literal: true

require "roby/test/self"
require "roby/relations/incremental_transitive_closure"
require "rgl/mutable"

module Roby
    module Relations
        describe IncrementalTransitiveClosure do
            describe "#reachable?" do
                attr_reader :incremental_transitive_closure

                before do
                    @incremental_transitive_closure = IncrementalTransitiveClosure.new
                end

                describe "adding relations" do
                    it "adds edge between vertex" do
                        incremental_transitive_closure.added_edge(0, 1)
                        assert incremental_transitive_closure.graph.has_edge?(0, 1)
                        refute incremental_transitive_closure.graph.has_edge?(1, 0)
                    end

                    it "adds indirect edges between vertex" do
                        incremental_transitive_closure.added_edge(0, 1)
                        incremental_transitive_closure.added_edge(1, 2)
                        assert incremental_transitive_closure.graph.has_edge?(0, 2)
                        refute incremental_transitive_closure.graph.has_edge?(2, 0)

                        incremental_transitive_closure.added_edge(3, 1)
                        assert incremental_transitive_closure.graph.has_edge?(3, 1)
                        assert incremental_transitive_closure.graph.has_edge?(3, 2)
                        refute incremental_transitive_closure.graph.has_edge?(3, 0)

                        incremental_transitive_closure.added_edge(4, 5)
                        incremental_transitive_closure.added_edge(2, 4)
                        assert incremental_transitive_closure.graph.has_edge?(2, 5)
                        assert incremental_transitive_closure.graph.has_edge?(1, 5)
                    end

                    it "ignores add edge if both edges are the same" do
                        incremental_transitive_closure.added_edge(0, 1)
                        incremental_transitive_closure.added_edge(1, 2)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 3)
                        incremental_transitive_closure.added_edge(2, 2)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 3)
                    end
                end

                describe "removing relations" do
                    it "removes edge" do
                        incremental_transitive_closure.added_edge(0, 1)
                        incremental_transitive_closure.added_edge(1, 2)
                        incremental_transitive_closure.added_edge(3, 2)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 4)
                        assert incremental_transitive_closure.graph.has_edge?(3, 2)
                        incremental_transitive_closure.removed_edge(3, 2)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 4)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 3)
                        refute incremental_transitive_closure.graph.has_edge?(3, 2)
                    end

                    it "does nothing if it removes non-existent edge" do
                        incremental_transitive_closure.added_edge(0, 1)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 2)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 1)
                        incremental_transitive_closure.removed_edge(1, 2)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 2)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 1)
                    end

                    it "resets representation if removed edge of target vertex"\
                       "containing children" do
                        incremental_transitive_closure.added_edge(0, 1)
                        incremental_transitive_closure.added_edge(1, 2)
                        incremental_transitive_closure.removed_edge(0, 1)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 0)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 0)
                    end

                    it "resets representation if removed edge of source vertex "\
                       "containing parents" do
                        incremental_transitive_closure.added_edge(0, 1)
                        incremental_transitive_closure.added_edge(1, 2)
                        incremental_transitive_closure.removed_edge(1, 2)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 0)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 0)
                    end

                    it "removes vertex" do
                        incremental_transitive_closure.added_edge(0, 1)
                        incremental_transitive_closure.added_edge(1, 2)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 3)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 3)
                        incremental_transitive_closure.removed_vertex(2)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 2)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 1)
                    end

                    it "does nothing if it removes inexistent vertex" do
                        incremental_transitive_closure.added_edge(0, 1)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 2)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 1)
                        incremental_transitive_closure.removed_vertex(3)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 2)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 1)
                    end

                    it "resets representation if removed vertex containing children" do
                        incremental_transitive_closure.added_edge(0, 1)
                        incremental_transitive_closure.added_edge(1, 2)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 3)
                        incremental_transitive_closure.removed_vertex(1)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 0)
                        assert_equal(incremental_transitive_closure.graph.num_edges, 0)
                    end
                end

                describe "reachability tests" do
                    it "verifies reachability of cached graph" do
                        g = Relations::BidirectionalDirectedAdjacencyGraph.new

                        g.add_vertex(0)
                        g.add_vertex(1)
                        g.add_vertex(2)
                        g.add_edge(0, 1)
                        incremental_transitive_closure.added_edge(0, 1)
                        g.add_edge(1, 2)
                        incremental_transitive_closure.added_edge(1, 2)

                        g.add_vertex(3)
                        g.add_edge(3, 1)
                        incremental_transitive_closure.added_edge(3, 1)

                        assert_equal(incremental_transitive_closure.graph.num_vertices, 4)
                        assert incremental_transitive_closure.reachable?(0, 2, g)
                        assert incremental_transitive_closure.reachable?(1, 2, g)
                        assert incremental_transitive_closure.reachable?(3, 2, g)
                        refute incremental_transitive_closure.reachable?(2, 1, g)
                        refute incremental_transitive_closure.reachable?(2, 0, g)
                        refute incremental_transitive_closure.reachable?(2, 0, g)
                        refute incremental_transitive_closure.reachable?(0, 3, g)
                    end

                    it "verifies direct reachability by exploring graph" do
                        g = Relations::BidirectionalDirectedAdjacencyGraph.new

                        g.add_vertex(0)
                        g.add_vertex(1)
                        g.add_vertex(2)
                        g.add_edge(0, 1)
                        g.add_edge(1, 2)
                        g.add_vertex(3)
                        g.add_edge(3, 1)

                        assert_equal(incremental_transitive_closure.graph.num_vertices, 0)
                        assert incremental_transitive_closure.reachable?(0, 1, g)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 3)
                        assert incremental_transitive_closure.reachable?(3, 1, g)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 4)
                        refute incremental_transitive_closure.reachable?(2, 1, g)
                    end

                    it "verifies reachability by exploring vertex fully" do
                        g = Relations::BidirectionalDirectedAdjacencyGraph.new

                        g.add_vertex(0)
                        g.add_vertex(1)
                        g.add_vertex(2)
                        g.add_vertex(3)
                        g.add_vertex(4)
                        g.add_vertex(5)
                        g.add_edge(0, 1)
                        g.add_edge(1, 2)
                        g.add_edge(2, 3)
                        g.add_edge(2, 5)
                        g.add_edge(3, 4)

                        assert incremental_transitive_closure.reachable?(0, 4, g)
                        assert incremental_transitive_closure.reachable?(0, 5, g)
                    end

                    it "verifies indirect reachability by exploring graph" do
                        g = Relations::BidirectionalDirectedAdjacencyGraph.new

                        g.add_vertex(0)
                        g.add_vertex(1)
                        g.add_vertex(2)
                        g.add_edge(0, 1)
                        g.add_edge(1, 2)
                        g.add_vertex(3)
                        g.add_edge(3, 1)

                        assert_equal(incremental_transitive_closure.graph.num_vertices, 0)
                        assert incremental_transitive_closure.reachable?(0, 2, g)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 3)
                        assert incremental_transitive_closure.reachable?(3, 2, g)
                        assert_equal(incremental_transitive_closure.graph.num_vertices, 4)
                        refute incremental_transitive_closure.reachable?(2, 0, g)
                    end
                end
            end
        end
    end
end
