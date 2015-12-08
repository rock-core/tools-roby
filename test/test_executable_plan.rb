require 'roby/test/self'

module Roby
    describe ExecutablePlan do
        describe "DAG graphs" do
            attr_reader :graph, :graph_m, :chain

            def prepare(dag)
                graph_m = Relations::Graph.new_submodel(dag: dag)
                @graph = graph_m.new(observer: ExecutablePlan.new)
                vertex_m = Class.new do
                    include Relations::DirectedRelationSupport
                    attr_reader :relation_graphs
                    def initialize(relation_graphs = Hash.new)
                        @relation_graphs = relation_graphs
                    end
                    def read_write?; true end
                end
                @chain = (1..10).map { vertex_m.new(graph => graph, graph_m => graph) }
                chain.each_cons(2) { |a, b| graph.add_relation(a, b, nil) }
            end

            it "does not raise CycleFoundError if an edge creates a cycle if dag is false" do
                prepare(false)
                graph.add_relation(chain[-1], chain[0])
            end
            it "raises CycleFoundError if an edge creates a DAG if dag is true" do
                prepare(true)
                assert_raises(Relations::CycleFoundError) do
                    graph.add_relation(chain[-1], chain[0])
                end
            end
        end

        describe "edge hooks" do
            it "calls the relation hooks on #replace" do
                (p, c1), (c11, c12, c2, c3) = prepare_plan missions: 2, tasks: 4, model: Roby::Tasks::Simple
                p.depends_on c1, model: Roby::Tasks::Simple
                c1.depends_on c11
                c1.depends_on c12
                p.depends_on c2
                c1.stop_event.signals c2.start_event
                c1.start_event.forward_to c1.stop_event
                c11.success_event.forward_to c1.success_event

                # Replace c1 by c3 and check that the hooks are properly called
                FlexMock.use do |mock|
                    p.singleton_class.class_eval do
                        define_method('removed_child') do |child|
                            mock.removed_hook(self, child)
                        end
                    end

                    mock.should_receive(:removed_hook).with(p, c1).once
                    mock.should_receive(:removed_hook).with(p, c2)
                    mock.should_receive(:removed_hook).with(p, c3)
                    plan.replace(c1, c3)
                end
            end

            it "calls the relation hooks on #replace_task" do
                (p, c1), (c11, c12, c2, c3) = prepare_plan missions: 2, tasks: 4, model: Roby::Tasks::Simple
                p.depends_on c1, model: Roby::Tasks::Simple
                c1.depends_on c11
                c1.depends_on c12
                p.depends_on c2
                c1.stop_event.signals c2.start_event
                c1.start_event.forward_to c1.stop_event
                c11.success_event.forward_to c1.success_event

                # Replace c1 by c3 and check that the hooks are properly called
                FlexMock.use do |mock|
                    p.singleton_class.class_eval do
                        define_method('removed_child') do |child|
                            mock.removed_hook(self, child)
                        end
                    end

                    mock.should_receive(:removed_hook).with(p, c1).once
                    mock.should_receive(:removed_hook).with(p, c2)
                    mock.should_receive(:removed_hook).with(p, c3)
                    plan.replace_task(c1, c3)
                end
            end

            it "properly synchronize plans on relation addition even if the adding hook raises" do
                model = Task.new_submodel
                t1, t2 = model.new, model.new
                flexmock(t1).should_receive(:adding_child).and_raise(RuntimeError)

                plan.add_mission(t1)
                assert_equal(plan, t1.plan)
                assert_raises(RuntimeError) do
                    t1.depends_on t2
                end
                assert_equal(plan, t1.plan)
                assert_equal(plan, t2.plan)
                assert(plan.include?(t2))
            end

            describe "generic hook dispatching" do
                let(:klass) do
                    Class.new do
                        attr_reader :relation_graphs
                        def initialize(graphs = Hash.new)
                            @relation_graphs = graphs
                        end
                        def read_write?; true end
                    end
                end
                let(:space) { Roby.RelationSpace(klass) }
                let(:graphs) { space.instanciate }
                def create_node(name = nil)
                    obj = klass.new(graphs)
                    if name
                        obj.singleton_class.class_eval do
                            define_method(:inspect) { name }
                        end
                    end
                    obj
                end
                attr_reader :relation
                before do
                    @relation = space.relation :R, child_name: 'child'
                    @plan = ExecutablePlan.new
                    ExecutionEngine.new(@plan)
                end
                let(:graphs) { space.instanciate(observer: plan) }
                let(:parent) { create_node("parent") }
                let(:child)  { create_node("child") }

                it "calls added_CHILD_NAME and adding_CHILD_NAME on addition" do
                    flexmock(parent).should_receive(:adding_child).
                        with(child, info = flexmock).once.ordered
                    flexmock(parent.relation_graphs[relation]).
                        should_receive(:add_edge).with(parent, child, info).once.ordered
                    flexmock(parent).should_receive(:added_child).
                        with(child, info).once.ordered

                    parent.add_child child, info
                end
                it "does not add the edge if adding_CHILD_NAME raises" do
                    flexmock(parent).should_receive(:adding_child).
                        with(child, info = flexmock).once.
                        and_raise(ArgumentError)
                    assert_raises(ArgumentError) { parent.add_child child, info }
                    assert !parent.child_object?(child, relation)
                end
                it "adds the edge even if added_CHILD_NAME raises" do
                    flexmock(parent).should_receive(:added_child).
                        with(child, info = flexmock).once.
                        and_raise(ArgumentError)
                    assert_raises(ArgumentError) { parent.add_child child, info }
                    assert parent.child_object?(child, relation)
                end
                it "calls removed_CHILD_NAME and removing_CHILD_NAME on removal" do
                    parent.add_child child
                    flexmock(parent).should_receive(:removing_child).
                        with(child).once.ordered
                    flexmock(parent.relation_graphs[relation]).
                        should_receive(:remove_edge).with(parent, child).once.ordered
                    flexmock(parent).should_receive(:removed_child).
                        with(child).once.ordered
                    parent.remove_child child
                end
                it "does not remove the edge if adding_CHILD_NAME raises" do
                    parent.add_child child
                    flexmock(parent).should_receive(:removing_child).
                        with(child).once.
                        and_raise(ArgumentError)
                    assert_raises(ArgumentError) { parent.remove_child child }
                    assert parent.child_object?(child, relation)
                end
                it "removes the edge even if added_CHILD_NAME raises" do
                    parent.add_child child
                    flexmock(parent).should_receive(:removed_child).
                        with(child).once.
                        and_raise(ArgumentError)
                    assert_raises(ArgumentError) { parent.remove_child child }
                    assert !parent.child_object?(child, relation)
                end
            end
        end
    end
end

