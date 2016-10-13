require 'roby/test/self'

module Roby
    module Relations
        describe Graph do
            describe "#reachable?" do
                attr_reader :graph
                before do
                    graph_m = Graph.new_submodel
                    @graph = graph_m.new
                end

                it "returns true if the target can be reached from the source" do
                    source, obj, target = (1..3).map { Object.new }
                    graph.add_edge(source, obj, nil)
                    graph.add_edge(obj, target, nil)
                    assert graph.reachable?(source, target)
                end
                it "returns true if target == source" do
                    obj = Object.new
                    graph.add_vertex(obj)
                    assert graph.reachable?(obj, obj)
                end
                it "returns false if the two are not reachable" do
                    source, obj, target = (1..3).map { Object.new }
                    graph.add_edge(source, obj, nil)
                    graph.add_vertex(target)
                    refute graph.reachable?(source, target)
                end
            end

            describe "#copy_subgraph_to" do
                attr_reader :old_graph, :new_graph
                attr_reader :old_a, :old_b, :new_a, :new_b
                before do
                    graph_m = Graph.new_submodel
                    @old_graph = graph_m.new
                    @new_graph = graph_m.new
                    @old_a, @old_b, @new_a, @new_b = *(1..4).map { Object.new }
                end

                it "copies the edges to their mapped equivalents" do
                    old_graph.add_edge(old_a, old_b, info = Object.new)
                    old_graph.copy_subgraph_to(new_graph, old_a => new_a, old_b => new_b)
                    assert new_graph.has_edge?(new_a, new_b)
                    assert_same info, new_graph.edge_info(new_a, new_b)
                end

                it "ignores edges for which the source does not have a mapping" do
                    old_graph.add_edge(old_a, old_b, info = Object.new)
                    old_graph.copy_subgraph_to(new_graph, old_b => new_b)
                    refute new_graph.has_edge?(new_a, new_b)
                end

                it "ignores edges for which the target does not have a mapping" do
                    old_graph.add_edge(old_a, old_b, info = Object.new)
                    old_graph.copy_subgraph_to(new_graph, old_a => new_a)
                    refute new_graph.has_edge?(new_a, new_b)
                end
            end

            describe "#find_edge_difference" do
                attr_reader :graph, :mapped_graph
                attr_reader :a, :b, :mapped_a, :mapped_b
                before do
                    graph_m = Graph.new_submodel
                    @graph = graph_m.new
                    @mapped_graph = graph_m.new
                    @a, @b, @mapped_a, @mapped_b = *(1..4).map { Object.new }
                end
                it "returns :num_edges_differ if the two graphs have a different number of edges" do
                    graph.add_edge(a, b, nil)
                    assert_equal [:num_edges_differ], graph.find_edge_difference(mapped_graph, Hash.new)
                end
                it "returns :missing_mapping if the source of an edge is not mapped" do
                    graph.add_edge(a, b, nil)
                    mapped_graph.add_edge(mapped_a, mapped_b, nil)
                    assert_equal [:missing_mapping, a], graph.find_edge_difference(mapped_graph, b => mapped_b)
                end
                it "returns :missing_mapping if the target of an edge is not mapped" do
                    graph.add_edge(a, b, nil)
                    mapped_graph.add_edge(mapped_a, mapped_b, nil)
                    assert_equal [:missing_mapping, b], graph.find_edge_difference(mapped_graph, a => mapped_a)
                end
                it "returns :missing_edge if the mapped source of an edge is not present in the target graph" do
                    graph.add_edge(a, b, nil)
                    mapped_graph.add_edge(Object.new, mapped_b, nil)
                    assert_equal [:missing_edge, a, b], graph.find_edge_difference(mapped_graph, a => mapped_a, b => mapped_b)
                end
                it "returns :missing_edge if the mapped target of an edge is not present in the target graph" do
                    graph.add_edge(a, b, nil)
                    mapped_graph.add_edge(mapped_a, Object.new, nil)
                    assert_equal [:missing_edge, a, b], graph.find_edge_difference(mapped_graph, a => mapped_a, b => mapped_b)
                end
                it "returns :missing_edge if the mapped edge is not present in the target graph" do
                    graph.add_edge(a, b, nil)
                    mapped_graph.add_edge(mapped_a, Object.new, nil)
                    mapped_graph.add_vertex(mapped_b)
                    assert_equal [:missing_edge, a, b], graph.find_edge_difference(mapped_graph, a => mapped_a, b => mapped_b)
                end
                it "returns :differing_edge_info if the edge and the mapped edge have different info" do
                    graph.add_edge(a, b, Object.new)
                    mapped_graph.add_edge(mapped_a, mapped_b, Object.new)
                    assert_equal [:differing_edge_info, a, b], graph.find_edge_difference(mapped_graph, a => mapped_a, b => mapped_b)
                end
                it "returns nil if they are identical" do
                    graph.add_edge(a, b, info = Object.new)
                    mapped_graph.add_edge(mapped_a, mapped_b, info)
                    assert_nil graph.find_edge_difference(mapped_graph, a => mapped_a, b => mapped_b)
                end
            end

            describe "#try_updating_existing_edge_info" do
                attr_reader :graph, :a, :b
                before do
                    graph_m = Graph.new_submodel
                    @graph = graph_m.new
                    @a, @b = Object.new, Object.new
                end

                it "returns false if the edge does not exist" do
                    refute graph.try_updating_existing_edge_info(a, b, Object.new)
                end
                it "updates the edge info if the current info is nil, and returns true" do
                    info = Object.new
                    graph.add_edge(a, b, nil)
                    assert graph.try_updating_existing_edge_info(a, b, info)
                    assert_same info, graph.edge_info(a, b)
                end
                it "returns true if the old and new edge info are equal" do
                    info = Object.new
                    graph.add_edge(a, b, info)
                    assert graph.try_updating_existing_edge_info(a, b, info)
                    assert_same info, graph.edge_info(a, b)
                end
                it "calls #merge_info to merge the info" do
                    graph.add_edge(a, b, old_info = Object.new)
                    flexmock(graph).should_receive(:merge_info).with(a, b, old_info, new_info = Object.new).
                        once.and_return(info = flexmock)
                    assert graph.try_updating_existing_edge_info(a, b, new_info)
                    assert_same info, graph.edge_info(a, b)
                end
                it "raises if the value returned by #merge_info is nil" do
                    graph.add_edge(a, b, Object.new)
                    flexmock(graph).should_receive(:merge_info).and_return(nil)
                    assert_raises(ArgumentError) do
                        graph.try_updating_existing_edge_info(a, b, Object.new)
                    end
                end
            end
            
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
                attr_reader :graph_m
                before do
                    @graph_m = Graph.new_submodel
                end

                it "notifies the edge removals" do
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

                it "returns true if the vertex had in relations" do
                    graph = graph_m.new
                    graph.add_edge(Object.new, obj = Object.new, nil)
                    assert graph.remove_vertex(obj)
                end
                it "returns true if the vertex had out relations" do
                    graph = graph_m.new
                    graph.add_edge(obj = Object.new, Object.new, nil)
                    assert graph.remove_vertex(obj)
                end
                it "returns false if the vertex did not have relations" do
                    graph = graph_m.new
                    graph.add_vertex(obj = Object.new)
                    refute graph.remove_vertex(obj)
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

            describe "the observer" do
                attr_reader :graph, :parent, :grandparent, :observer, :a, :b
                before do
                    @observer = flexmock
                    @graph = Graph.new_submodel.new(observer: observer)
                    @parent = Graph.new_submodel.new(subsets: [graph], observer: observer)
                    @grandparent = Graph.new_submodel.new(subsets: [parent], observer: observer)
                    @a, @b = Object.new, Object.new
                end

                it "calls the remove*edge methods with the list of graphs that have been updated in the hierarchy" do
                    observer.should_receive(:adding_edge)
                    observer.should_receive(:added_edge)
                    parent.add_relation(a, b, nil)
                    observer.should_receive(:removing_edge).with(a, b, [parent.class, grandparent.class]).
                        once.globally.ordered.
                        and_return { assert parent.has_edge?(a, b) }
                    observer.should_receive(:removed_edge).with(a, b, [parent.class, grandparent.class]).
                        once.globally.ordered.
                        and_return { refute parent.has_edge?(a, b) }
                    parent.remove_relation(a, b)
                end

                it "calls the add*edge methods with the list of graphs that have been updated in the hierarchy" do
                    grandparent.add_edge(a, b, nil)
                    observer.should_receive(:adding_edge).with(a, b, [graph.class, parent.class], nil).
                        once.globally.ordered.
                        and_return { refute graph.has_edge?(a, b) }
                    observer.should_receive(:added_edge).with(a, b, [graph.class, parent.class], nil).
                        once.globally.ordered.
                        and_return { assert graph.has_edge?(a, b) }
                    graph.add_relation(a, b, nil)
                end

                it "calls the updat*edge_info methods with the edge, graph model and new info" do
                    observer.should_receive(:adding_edge)
                    observer.should_receive(:added_edge)

                    old_info = flexmock
                    new_info = flexmock
                    graph.add_relation(a, b, old_info)
                    observer.should_receive(:updating_edge_info).with(a, b, graph.class, new_info).
                        once.globally.ordered.
                        and_return { assert_same old_info, graph.edge_info(a, b) }
                    observer.should_receive(:updated_edge_info).with(a, b, graph.class, new_info).
                        once.globally.ordered.
                        and_return { assert_same new_info, graph.edge_info(a, b) }
                    graph.set_edge_info(a, b, new_info)
                end
            end

            describe "#recursive_subsets" do
                it "returns all the subgraphs in the graph hierarchy" do
                    graph_m = Graph.new_submodel
                    graph = graph_m.new
                    parent_sibling = graph_m.new
                    parent = graph_m.new(subsets: [graph])
                    grandparent = graph_m.new(subsets: [parent, parent_sibling])
                    assert_equal Set[graph, parent, parent_sibling], grandparent.recursive_subsets
                end
            end

            describe "#subset?" do
                attr_reader :graph, :parent, :parent_sibling, :grandparent
                before do
                    graph_m = Graph.new_submodel
                    @graph = graph_m.new
                    @parent_sibling = graph_m.new
                    @parent = graph_m.new(subsets: [graph])
                    @grandparent = graph_m.new(subsets: [parent, parent_sibling])
                end

                it "returns false for two unrelated graphs" do
                    refute parent.subset?(parent_sibling)
                end
                it "returns true for itself" do
                    assert parent.subset?(parent)
                end
                it "returns true for a direct subset" do
                    assert grandparent.subset?(parent)
                end
                it "returns true for a subset of one of its subsets" do
                    assert grandparent.subset?(graph)
                end
            end

            describe "#root_graph" do
                it "returns itself if it has no parents" do
                    graph_m = Graph.new_submodel
                    graph = graph_m.new
                    assert_same graph, graph.root_graph
                end
                it "returns the root of the hierarchy" do
                    graph_m = Graph.new_submodel
                    graph = graph_m.new
                    parent = graph_m.new(subsets: [graph])
                    grandparent = graph_m.new(subsets: [parent])
                    assert_same grandparent, graph.root_graph
                end
            end

            describe "#superset_of" do
                it "adds the argument as a subset of self" do
                    graph_m = Graph.new_submodel
                    graph = graph_m.new
                    parent = graph_m.new
                    parent.superset_of(graph)
                    assert parent.subset?(graph)
                    assert_same parent, graph.parent
                end
                it "raises if the argument is not empty" do
                    graph_m = Graph.new_submodel
                    graph = graph_m.new
                    graph.add_vertex(Object.new)
                    parent = graph_m.new
                    assert_raises(ArgumentError) do
                        parent.superset_of(graph)
                    end
                end
            end

            describe "#has_edge_in_hierarchy?" do
                attr_reader :graph, :parent
                before do
                    graph_m = Graph.new_submodel
                    @graph = graph_m.new
                    @parent = graph_m.new(subsets: [graph])
                end

                it "returns true if this graph's parents has the edge" do
                    parent.add_relation(a = Object.new, b = Object.new, nil)
                    assert graph.has_edge_in_hierarchy?(a, b)
                end
                it "returns true if this graph has the edge" do
                    graph.add_relation(a = Object.new, b = Object.new, nil)
                    assert graph.has_edge_in_hierarchy?(a, b)
                end
                it "returns false if this graph and none of its parents has the edge" do
                    assert !graph.has_edge_in_hierarchy?(a = Object.new, b = Object.new)
                end
            end
        end
    end
end

