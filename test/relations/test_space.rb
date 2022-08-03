# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Relations
        describe Space do
            let(:support_class) do
                Class.new do
                    attr_reader :relation_graphs

                    def initialize(graphs = {})
                        @relation_graphs = graphs
                    end

                    def plan
                        Hash.new { |h, k| k }
                    end
                end
            end
            let(:space) { Roby.RelationSpace(support_class) }
            let(:graphs) { space.instanciate }
            def create_node(name = nil)
                obj = support_class.new(graphs)
                if name
                    obj.singleton_class.class_eval do
                        define_method(:inspect) { name }
                    end
                end
                obj
            end

            describe "#relation" do
                it "registers the relation on the space constant" do
                    r = space.relation :R1, child_name: :child
                    assert_same r, space::R1
                end
                it "defines child accessors" do
                    r = space.relation :R1, child_name: :child
                    n = create_node
                    assert n.respond_to?(:each_child)
                    assert n.respond_to?(:add_child)
                    assert n.respond_to?(:find_child)
                    assert n.respond_to?(:remove_child)
                end

                it "defines parent accessors if a parent_name is given" do
                    r = space.relation :R1, parent_name: :parent
                    assert create_node.respond_to?(:each_parent)
                end

                it "includes the extension module on the target class" do
                    r = space.relation :R1, child_name: :child
                    assert create_node.class.has_ancestor?(r::Extension)
                end
            end

            describe "#apply_on" do
                subject { Space.new }
                let(:relation_class) do
                    Class.new do
                        class << self
                            attr_reader :relation_spaces
                        end
                        @relation_spaces = []
                    end
                end
                it "includes DirectedRelationSupport on its argument" do
                    subject.apply_on(relation_class)
                    assert(relation_class <= DirectedRelationSupport)
                end
                it "registers the class so that new relations are applied on it" do
                    subject.apply_on(relation_class)
                    r = subject.relation :R
                    assert(relation_class <= r::Extension)
                end
                it "applies existing relations on the new klass" do
                    r1 = subject.relation :R1
                    subject.apply_on(relation_class)
                    assert(relation_class <= r1::Extension)
                end
                it "registers itself on the target's #relation_spaces attribute" do
                    mock = flexmock(relation_spaces: [], all_relation_spaces: [], include: nil)
                    subject.apply_on(mock)
                    assert_equal [subject], mock.relation_spaces
                end

                it "iterates over the target's supermodels and registers itself on their #all_relation_spaces attribute" do
                    root     = flexmock(relation_spaces: [], all_relation_spaces: [], include: nil)
                    submodel = flexmock(supermodel: root, relation_spaces: [], all_relation_spaces: [], include: nil)
                    subject.apply_on(submodel)
                    assert_equal [], root.relation_spaces
                    assert_equal [subject], root.all_relation_spaces
                    assert_equal [subject], submodel.relation_spaces
                    assert_equal [subject], submodel.all_relation_spaces
                end
            end

            describe "synthetized methods" do
                describe "single child relation" do
                    before do
                        space.relation :R, child_name: "child", single_child: true
                    end

                    it "has a nil accessor by default" do
                        assert !create_node.child
                    end

                    it "sets the accessor to the last child set" do
                        parent, child, other_child = create_node, create_node, create_node
                        parent.add_child child
                        assert_equal child, parent.child
                        parent.add_child other_child
                        assert_equal other_child, parent.child
                    end

                    it "resets the accessor to nil when the child is removed" do
                        parent, child = create_node, create_node
                        parent.add_child child
                        parent.remove_child child
                        assert_nil parent.child
                    end

                    it "resets the accessor to other children if there are some when the child is removed" do
                        parent, child, other_child = create_node, create_node, create_node
                        parent.add_child child
                        parent.add_child other_child
                        parent.remove_child other_child
                        assert_equal child, parent.child
                    end

                    it "resets its parents accessors to nil when it is removed from the graph" do
                        parent, child = create_node, create_node
                        parent.add_child child
                        parent.relation_graphs[space::R].remove_vertex(child)
                        assert !parent.child
                    end

                    it "resets its parents accessors to another child when it is removed from the graph" do
                        parent, child, other_child = create_node, create_node, create_node
                        parent.add_child child
                        parent.add_child other_child
                        parent.relation_graph_for(space::R).remove_vertex(other_child)
                        assert_equal child, parent.child
                    end

                    describe "within a transaction" do
                        before do
                            @plan = Roby::Plan.new
                            @plan.add(@planned_task = Roby::Task.new)
                            @plan.add(@planning_task = Roby::Task.new)
                            @trsc = Roby::Transaction.new(@plan)
                        end

                        it "has nil accessors if the real task has nil accessors" do
                            assert_nil @trsc[@planning_task].planned_task
                            assert_nil @trsc[@planned_task].planning_task
                        end

                        it "wraps the child on first access" do
                            @planned_task.planned_by(@planning_task)
                            assert_equal @planning_task, @trsc[@planned_task]
                                .planning_task.__getobj__
                        end

                        it "sets the accessors to nil if the relation is removed" do
                            @planned_task.planned_by(@planning_task)
                            @trsc[@planned_task].remove_planning_task(
                                @trsc[@planning_task])
                            @trsc.commit_transaction
                            assert_nil @planned_task.planning_task
                        end

                        it "updates the accessors if updated in the transaction" do
                            @planned_task.planned_by(@planning_task)
                            @trsc[@planned_task].remove_planning_task(
                                @trsc[@planning_task])
                            @trsc[@planned_task].planned_by(
                                new_planning_task = Roby::Task.new)
                            @trsc.commit_transaction
                            assert_equal new_planning_task, @planned_task.planning_task
                        end

                        it "updates the parent on commit if updated in the transaction" do
                            @planned_task.planned_by(@planning_task)
                            new_planned_task = Roby::Task.new
                            @trsc[@planned_task].remove_planning_task(
                                @trsc[@planning_task])
                            new_planned_task.planned_by(
                                @trsc[@planning_task])
                            @trsc.commit_transaction
                            assert_equal @planning_task, new_planned_task.planning_task
                        end

                        it "handles relations modified between transactions" do
                            @planned_task.planned_by(@planning_task)
                            @plan.add(new_planned_task = Roby::Task.new)
                            @trsc[@planned_task].remove_planning_task(
                                @trsc[@planning_task])
                            @trsc[new_planned_task].planned_by(
                                @trsc[@planning_task])
                            @trsc.commit_transaction
                            assert_equal @planning_task, new_planned_task.planning_task
                        end
                    end
                end

                describe "#each_PARENT" do
                    before do
                        space.relation :R1, parent_name: "parent"
                    end
                    let(:recorder) { flexmock }
                    subject { create_node }

                    it "enumerates the object's parents" do
                        (parent = create_node).add_r1(subject)
                        recorder.should_receive(:called).with([parent]).once
                        subject.each_parent { |*c| recorder.called(c) }
                    end
                end

                describe "relation without embedded info" do
                    before do
                        space.relation :R1, child_name: "child", noinfo: true
                    end
                    let(:recorder) { flexmock }
                    subject { create_node }

                    describe "#find_CHILD" do
                        it "is passed the child only" do
                            subject.add_child(child = create_node)
                            recorder.should_receive(:called).with([child]).once
                            assert_nil(subject.find_child { |*c| recorder.called(c) })
                        end

                        it "returns nil if there are no matching children" do
                            assert_nil(subject.find_child { |c| false })
                        end

                        it "returns the first child for which the block returns true" do
                            subject.add_child(child = create_node)
                            assert_equal(child, subject.find_child { true })
                        end
                    end

                    describe "#each_CHILD" do
                        it "enumerates the object's children" do
                            subject.add_child(child = create_node)
                            recorder.should_receive(:called).with([child]).once
                            subject.each_child { |*c| recorder.called(c) }
                        end
                    end
                end

                describe "relation with embedded info" do
                    before do
                        space.relation :R1, child_name: "child", noinfo: false
                    end
                    let(:recorder) { flexmock }
                    subject { create_node }

                    describe "#find_CHILD" do
                        it "returns nil if there are no children" do
                            assert_nil subject.find_child
                        end

                        it "yields the child only if its argument is false" do
                            subject.add_child(child = create_node, info = flexmock)
                            recorder.should_receive(:called).with([child]).once
                            assert_nil subject.find_child(false) { |*c| recorder.called(c) }
                        end

                        it "yields the child and info" do
                            subject.add_child(child = create_node, info = flexmock)
                            recorder.should_receive(:called).with([child, info]).once
                            assert_nil(subject.find_child { |*c| recorder.called(c) })
                        end

                        it "returns nil if there are no matching children" do
                            assert_nil(subject.find_child { |c| false })
                        end

                        it "returns the first child for which the block returns true" do
                            subject.add_child(child = create_node)
                            assert_equal(child, subject.find_child { true })
                        end
                    end

                    describe "#each_CHILD" do
                        it "enumerates the object's children" do
                            subject.add_child(child = create_node, info = flexmock)
                            recorder.should_receive(:called).with([child, info]).once
                            subject.each_child { |*c| recorder.called(c) }
                        end
                        it "does not enumerate the info if with_info is false" do
                            subject.add_child(child = create_node, info = flexmock)
                            recorder.should_receive(:called).with([child]).once
                            subject.each_child(false) { |*c| recorder.called(c) }
                        end
                        it "passes the with_info parameter to a generated enumerator" do
                            subject.add_child(child = create_node, info = flexmock)
                            assert_equal [child], subject.each_child(false).to_a
                        end
                    end
                end
            end
        end
    end
end
