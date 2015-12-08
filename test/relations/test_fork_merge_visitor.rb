require 'roby/test/self'

module Roby
    module Relations
        describe ForkMergeVisitor do
            let :mock_value do
                value = flexmock
                value.should_receive(:fork).and_return(value)
                value.should_receive(:merge).and_return(value)
                value
            end

            let :graph do
                graph = BidirectionalDirectedAdjacencyGraph.new
                graph.add_edge 1, 21
                graph.add_edge 21, 3
                graph.add_edge 1, 22
                graph.add_edge 22, 3

                graph.add_edge 3, 4
                graph.add_edge 4, 5
                graph.add_edge 22, 5
                graph
            end

            describe "#count_in_out_degrees" do
                it "counts the in and out edges for each vertex" do
                    visitor = ForkMergeVisitor.new(graph, mock_value, 1)
                    in_degree, out_degree = visitor.compute_in_out_degrees(1, [21, 22])
                    assert_equal Hash[1 => 0, 21 => 1, 22 => 1, 3 => 2, 4 => 1, 5 => 2],
                        in_degree
                    assert_equal Hash[1 => 2, 21 => 1, 22 => 2, 3 => 1, 4 => 1],
                        out_degree
                end

                it "restricts itself to the subgraph defined by the origin argument" do
                    visitor = ForkMergeVisitor.new(graph, mock_value, 1)
                    in_degree, out_degree = visitor.compute_in_out_degrees(22, [3, 5])
                    assert_equal Hash[22 => 0, 3 => 1, 4 => 1, 5 => 2],
                        in_degree
                    assert_equal Hash[22 => 2, 3 => 1, 4 => 1],
                        out_degree
                end

                it "restricts itself to the subgraph defined by the neighbour argument" do
                    visitor = ForkMergeVisitor.new(graph, mock_value, 1)
                    in_degree, out_degree = visitor.compute_in_out_degrees(1, [21])
                    assert_equal Hash[1 => 0, 21 => 1, 3 => 1, 4 => 1, 5 => 1],
                        in_degree
                    assert_equal Hash[1 => 1, 21 => 1, 3 => 1, 4 => 1],
                        out_degree
                end
            end

            it "orders propagation in topological order" do
                visitor = ForkMergeVisitor.new(graph, mock_value, 1)
                flexmock(visitor) do |m|
                    m.should_receive(:handle_examine_vertex).with(1).once.ordered
                    m.should_receive(:handle_examine_vertex).with(21).once.ordered(:parallel_edges)
                    m.should_receive(:handle_examine_vertex).with(22).once.ordered(:parallel_edges)
                    m.should_receive(:handle_examine_vertex).with(3).once.ordered
                    m.should_receive(:handle_examine_vertex).with(4).once.ordered
                    m.should_receive(:handle_examine_vertex).with(5).once.ordered
                end
                visitor.visit
            end

            it "operates on the specified subgraph" do
                visitor = ForkMergeVisitor.new(graph, mock_value, 22)
                flexmock(visitor) do |m|
                    m.should_receive(:handle_examine_vertex).with(22).once.ordered
                    m.should_receive(:handle_examine_vertex).with(3).once.ordered
                    m.should_receive(:handle_examine_vertex).with(4).once.ordered
                    m.should_receive(:handle_examine_vertex).with(5).once.ordered
                end
                visitor.visit
            end

            it "can restrict the subgraph to a set of neighbours from the root" do
                visitor = ForkMergeVisitor.new(graph, mock_value, 1, [22])
                flexmock(visitor) do |m|
                    m.should_receive(:handle_examine_vertex).with(1).once.ordered
                    m.should_receive(:handle_examine_vertex).with(22).once.ordered
                    m.should_receive(:handle_examine_vertex).with(3).once.ordered
                    m.should_receive(:handle_examine_vertex).with(4).once.ordered
                    m.should_receive(:handle_examine_vertex).with(5).once.ordered
                end
                visitor.visit
            end

            it "forks and merges the value" do
                recorder = Class.new do
                    attr_reader :id

                    def initialize(id = [0])
                        @id = id
                        @fork_counter  = 0
                        @merge_counter = 0
                    end
                    def fork
                        self.class.new(@id + [@fork_counter += 1])
                    end
                    def merge(object)
                        self.class.new([[@id, object.id].to_set])
                    end
                end

                visitor = ForkMergeVisitor.new(graph, recorder.new, 1)
                visitor.visit
                assert_equal [0], visitor.vertex_to_object[1].id
                assert_equal [[0, 1], [0, 2]].to_set,
                    [visitor.vertex_to_object[21].id, visitor.vertex_to_object[22].id].to_set
                assert_equal [[[0, 1], [0, 2, 1]].to_set],
                    visitor.vertex_to_object[3].id
                assert_equal [[[0, 1], [0, 2, 1]].to_set],
                    visitor.vertex_to_object[4].id
                assert_equal [[[[[0, 1], [0, 2, 1]].to_set], [0,2,2]].to_set],
                    visitor.vertex_to_object[5].id
            end
        end
    end
end

