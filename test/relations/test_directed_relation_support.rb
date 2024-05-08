# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Relations
        describe DirectedRelationSupport do
            attr_reader :vertex_m, :graph

            before do
                @graph_m = graph_m = Graph.new_submodel
                @graph   = graph   = graph_m.new
                @vertex_m = Class.new(Object) do
                    include DirectedRelationSupport
                    define_method(:relation_graphs) { { graph_m => graph } }
                    define_method(:sorted_relations) { [graph_m] }
                end
            end

            describe "#clear_vertex" do
                it "returns true if the vertex had relations" do
                    graph.add_edge(v = vertex_m.new, vertex_m.new, nil)
                    assert v.clear_vertex
                end
                it "returns false if the vertex had no relations" do
                    graph.add_vertex(v = vertex_m.new)
                    refute v.clear_vertex
                end

                it "does not remove the strong relations with strong: false" do
                    flexmock(graph, strong?: true)
                    graph.add_edge(v = vertex_m.new, target = vertex_m.new, nil)
                    refute v.clear_vertex(remove_strong: false)
                    assert graph.has_edge?(v, target)
                end
            end
        end
    end
end
