require 'roby/test/self'

module Roby
    module Relations
        describe EventRelationGraph do
            attr_reader :vertex_m, :relation_m, :space
            before do
                @vertex_m = Class.new do
                    include DirectedRelationSupport
                    attr_reader :task
                    def initialize(task, relation_graphs)
                        @relation_graphs = relation_graphs
                        @task = task
                    end
                end
                @space = Roby::RelationSpace(vertex_m)
                @relation_m = space.relation :R, child_name: 'child', graph: EventRelationGraph
            end

            let(:relation_graphs) { space.instanciate }
            let(:relation) { relation_graphs[relation_m] }
            let(:task_a) { Object.new }
            let(:event_a) { vertex_m.new(task_a, relation_graphs) }
            let(:task_b) { Object.new }
            let(:event_b) { vertex_m.new(task_b, relation_graphs) }

            it "does not relate tasks that are not linked in the graph" do
                assert !relation.related_tasks?(task_a, task_a)
            end

            it "relate tasks whose events are linked in the graph" do
                event_a.add_child event_b
                assert relation.related_tasks?(task_a, task_b)
            end

            it "does not relate tasks whose events have been unlinked from the graph" do
                event_a.add_child event_b
                event_a.remove_child event_b
                assert !relation.related_tasks?(task_a, task_a)
            end

            it "keeps the tasks in the task graph after the events have been unlinked" do
                event_a.add_child event_b
                event_a.remove_child event_b
                assert relation.task_graph.has_vertex?(task_a)
                assert relation.task_graph.has_vertex?(task_b)
            end

            it "removes the tasks from the task graph once the events have beeen cleared" do
                event_a.add_child event_b
                event_a.remove_child event_b
                event_a.clear_vertex
                event_b.clear_vertex
                assert !relation.task_graph.has_vertex?(task_a)
                assert !relation.task_graph.has_vertex?(task_b)
            end
        end
    end
end
