require 'roby/test/self'

module Roby
    module Relations
        describe Graph do
            describe "#replace_vertex" do
                attr_reader :graph
                attr_reader :old, :new, :parent, :child
                before do
                    graph_m = Graph.new_submodel
                    @graph = graph_m.new
                    vertices = (1..4).map { Object.new }
                    vertices.each { |v| graph.add_vertex(v) }
                    @old, @new, @parent, @child = *vertices
                end

                it "moves the in-edges of the old vertex to the new vertex" do
                    graph.add_edge(parent, old, (info = Object.new))
                    graph.replace_vertex(old, new)
                    assert graph.has_edge?(parent, new)
                    assert_same info, graph.edge_info(parent, new)
                    assert !graph.has_edge?(parent, old)
                end

                it "does not touch the existing in-edges of the new vertex" do
                    graph.add_edge(parent, new, (info = Object.new))
                    graph.replace_vertex(old, new)
                    assert graph.has_edge?(parent, new)
                    assert_same info, graph.edge_info(parent, new)
                    assert !graph.has_edge?(parent, old)
                end
                
                it "moves the out-edges of the old vertex to the new vertex" do
                    graph.add_edge(old, child, (info = Object.new))
                    graph.replace_vertex(old, new)
                    assert graph.has_edge?(new, child)
                    assert_same info, graph.edge_info(new, child)
                    assert !graph.has_edge?(old, child)
                end
                
                it "does not touch the existing out-edges of the new vertex" do
                    graph.add_edge(new, child, (info = Object.new))
                    graph.replace_vertex(old, new)
                    assert graph.has_edge?(new, child)
                    assert_same info, graph.edge_info(new, child)
                    assert !graph.has_edge?(old, child)
                end

                it "removes the old vertex if remove is true" do
                    graph.replace_vertex(old, new, remove: true)
                    assert !graph.has_vertex?(old)
                end

                it "leaves the old vertex in the graph if remove is false" do
                    graph.replace_vertex(old, new, remove: false)
                    assert graph.has_vertex?(old)
                end
            end

            describe "#remove_vertex" do
                it "notifies the edge removals" do
                    graph_m = Graph.new_submodel
                    parent, obj, child = (1..3).map { Object.new }
                    observer = flexmock do |f|
                        f.should_receive(:adding_edge)
                        f.should_receive(:added_edge)
                        f.should_receive(:removing_edge).with(parent, obj, [graph_m]).once
                        f.should_receive(:removing_edge).with(obj, child, [graph_m]).once
                        f.should_receive(:removed_edge).with(parent, obj, [graph_m]).once
                        f.should_receive(:removed_edge).with(obj, child, [graph_m]).once
                    end
                    graph = graph_m.new(observer: observer)
                    graph.add_edge(parent, obj, nil)
                    graph.add_edge(obj, child, nil)
                    graph.remove_vertex(obj)
                end
            end

            describe "behaviour related to edge info" do
                let(:graph_m) { Graph.new_submodel }
                subject { graph_m.new }
                let(:vertex_m) do
                    Class.new do
                        include DirectedRelationSupport
                        attr_reader :relation_graphs
                        def initialize(relation_graphs = Hash.new)
                            @relation_graphs = relation_graphs
                        end
                    end
                end
                let(:parent) { vertex_m.new(subject => subject, graph_m => subject) }
                let(:child)  { vertex_m.new(subject => subject, graph_m => subject) }

                it "is nil by default" do
                    parent.add_child_object(child, graph_m)
                    assert_equal nil, parent[child, graph_m]
                end

                it "can be overriden from a nil to a non-nil value" do
                    parent.add_child_object(child, graph_m, nil)
                    parent.add_child_object(child, graph_m, false)
                    assert_equal false, parent[child, graph_m]
                end

                it "raises ArgumentError if updated from a non-nil to a non-nil value" do
                    parent.add_child_object(child, graph_m, false)
                    assert_raises(ArgumentError) { parent.add_child_object(child, graph_m, true) }
                end

                it "uses the merge_info method if updating a non-nil to a non-nil value" do
                    parent.add_child_object(child, graph_m, false)
                    flexmock(subject).should_receive(:merge_info).
                        with(parent, child, false, true).
                        and_return(2)
                    parent.add_child_object(child, graph_m, true)
                    assert_equal 2, parent[child, graph_m]
                end

                describe "subgraph handling" do
                    attr_reader :graph_m, :graph, :superset_graph_m, :superset_graph
                    before do
                        @graph_m = Graph.new_submodel
                        @superset_graph_m = Graph.new_submodel
                        @graph = graph_m.new
                        @superset_graph = superset_graph_m.new
                        superset_graph.superset_of(graph)
                    end

                    let(:parent) { vertex_m.new(
                        graph => graph, graph_m => graph,
                        superset_graph => superset_graph, superset_graph_m => superset_graph) }
                    let(:child) { vertex_m.new(
                        graph => graph, graph_m => graph,
                        superset_graph => superset_graph, superset_graph_m => superset_graph) }

                    describe "creating edges in superset graphs" do
                        it "does not create edges in the subgraphs" do
                            parent.add_child_object(child, superset_graph_m, info = flexmock)
                            assert !graph.has_vertex?(parent)
                            assert !graph.has_vertex?(child)
                        end
                    end

                    describe "creating edges in subset graphs" do
                        it "can be created even if the superset graph has an edge already" do
                            parent.add_child_object(child, superset_graph_m, superset_info = flexmock)
                            parent.add_child_object(child, graph_m, info = flexmock)
                            assert_equal superset_info, parent[child, superset_graph_m]
                            assert_equal info, parent[child, graph_m]
                        end
                        it "sets the edge info only at the level it has been set" do
                            parent.add_child_object(child, graph_m, info = flexmock)
                            assert_equal info, parent[child, graph_m]
                            assert_equal nil, parent[child, superset_graph_m]
                        end
                        it "updates the edge info only at the level it is being updated" do
                            parent.add_child_object(child, graph_m)
                            assert_equal nil, parent[child, superset_graph_m]
                            assert_equal nil, parent[child, graph_m]
                            parent.add_child_object(child, superset_graph_m, info = flexmock)
                            assert_equal info, parent[child, superset_graph_m]
                            assert_equal nil, parent[child, graph_m]
                        end
                    end
                end
            end
        end
    end
end

