require 'roby/test/self'

module Roby
    module Relations
        describe Graph do
            describe "DAG graph" do
                let(:vertex_m) do
                    Class.new do
                        include DirectedRelationSupport
                        attr_reader :relation_graphs
                        def initialize(relation_graphs = Hash.new)
                            @relation_graphs = relation_graphs
                        end
                    end
                end

                it "does not raise CycleFoundError if an edge creates a DAG if dag is false" do
                    chain = (1..10).map { vertex_m.new }
                    graph = Graph.new_submodel(dag: false).new("test")
                    chain.each_cons(2) { |a, b| graph.add_relation(a, b, nil) }
                    graph.add_relation(chain[-1], chain[0])
                end
                it "raises CycleFoundError if an edge creates a DAG if dag is true" do
                    chain = (1..10).map { vertex_m.new }
                    graph = Graph.new_submodel(dag: true).new("test")
                    chain.each_cons(2) { |a, b| graph.add_relation(a, b, nil) }
                    assert_raises(CycleFoundError) do
                        graph.add_relation(chain[-1], chain[0])
                    end
                end
            end

            describe "behaviour related to edge info" do
                let(:graph_m) { Graph.new_submodel }
                subject { graph_m.new("test") }
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
                        @graph = graph_m.new("graph")
                        @superset_graph = superset_graph_m.new("superset_graph")
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
                            flexmock(parent).should_receive(:adding_child_object).
                                with(child, [superset_graph_m], info = flexmock).once
                            flexmock(parent).should_receive(:added_child_object).
                                with(child, [superset_graph_m], info).once
                            parent.add_child_object(child, superset_graph_m, info)
                            assert !graph.include?(parent)
                            assert !graph.include?(child)
                        end
                    end

                    describe "creating edges in subset graphs" do
                        it "can be created even if the superset graph has an edge already" do
                            parent.add_child_object(child, superset_graph_m, superset_info = flexmock)
                            flexmock(parent).should_receive(:adding_child_object).
                                with(child, [graph_m], info = flexmock).once
                            flexmock(parent).should_receive(:added_child_object).
                                with(child, [graph_m], info).once
                            parent.add_child_object(child, graph_m, info)
                            assert_equal superset_info, parent[child, superset_graph_m]
                            assert_equal info, parent[child, graph_m]
                        end
                        it "sets the edge info only at the level it has been set" do
                            flexmock(parent).should_receive(:adding_child_object).
                                with(child, [graph_m, superset_graph_m], info = flexmock).once
                            flexmock(parent).should_receive(:added_child_object).
                                with(child, [graph_m, superset_graph_m], info).once
                            parent.add_child_object(child, graph_m, info)
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

