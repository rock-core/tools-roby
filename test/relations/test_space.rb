require 'roby/test/self'

module Roby
    module Relations
        describe Space do
            let(:klass) do
                Class.new do
                    attr_reader :relation_graphs
                    def initialize(graphs = Hash.new)
                        @relation_graphs = graphs
                    end
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
                it "includes DirectedRelationSupport on its argument" do
                    subject.apply_on(klass = Class.new)
                    assert(klass <= DirectedRelationSupport)
                end
                it "registers the class so that new relations are applied on it" do
                    subject.apply_on(klass = Class.new)
                    r = subject.relation :R
                    assert(klass <= r::Extension)
                end
                it "applies existing relations on the new klass" do
                    r1 = subject.relation :R1
                    subject.apply_on(klass = Class.new)
                    assert(klass <= r1::Extension)
                end
            end

            describe "synthetized methods" do
                describe "hooks" do
                    attr_reader :relation
                    before do
                        @relation = space.relation :R, child_name: 'child'
                    end
                    let(:parent) { create_node("parent") }
                    let(:child) { create_node("child") }

                    it "calls added_CHILD_NAME and adding_CHILD_NAME on addition" do
                        flexmock(parent).should_receive(:adding_child).
                            with(child, info = flexmock).once.ordered
                        flexmock(parent.relation_graphs[relation]).
                            should_receive(:__bgl_link).with(parent, child, info).once.ordered
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
                            should_receive(:unlink).with(parent, child).once.ordered
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
                describe "single child relation" do
                    before do
                        space.relation :R, child_name: 'child', single_child: true
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
                        assert_equal nil, parent.child
                    end

                    it "resets the accessor to other children if there are some" do
                        parent, child, other_child = create_node, create_node, create_node
                        parent.add_child child
                        parent.add_child other_child
                        parent.remove_child other_child
                        assert_equal child, parent.child
                    end
                end

                describe "#each_PARENT" do
                    before do
                        space.relation :R1, parent_name: 'parent'
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
                        space.relation :R1, child_name: 'child', noinfo: true
                    end
                    let(:recorder) { flexmock }
                    subject { create_node }

                    describe "#find_CHILD" do
                        it "returns nil if there are no children" do
                            assert_equal nil, subject.find_child
                        end

                        it "is passed the child only" do
                            subject.add_child(child = create_node)
                            recorder.should_receive(:called).with([child]).once
                            assert_equal nil, subject.find_child { |*c| recorder.called(c) }
                        end

                        it "returns nil if there are no matching children" do
                            assert_equal nil, subject.find_child { |c| false }
                        end

                        it "returns the first child for which the block returns true" do
                            subject.add_child(child = create_node)
                            assert_equal child, subject.find_child { true }
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
                        space.relation :R1, child_name: 'child', noinfo: false
                    end
                    let(:recorder) { flexmock }
                    subject { create_node }

                    describe "#find_CHILD" do
                        it "returns nil if there are no children" do
                            assert_equal nil, subject.find_child
                        end

                        it "yields the child only if its argument is false" do
                            subject.add_child(child = create_node, info = flexmock)
                            recorder.should_receive(:called).with([child]).once
                            assert_equal nil, subject.find_child(false) { |*c| recorder.called(c) }
                        end

                        it "yields the child and info" do
                            subject.add_child(child = create_node, info = flexmock)
                            recorder.should_receive(:called).with([child, info]).once
                            assert_equal nil, subject.find_child { |*c| recorder.called(c) }
                        end

                        it "returns nil if there are no matching children" do
                            assert_equal nil, subject.find_child { |c| false }
                        end

                        it "returns the first child for which the block returns true" do
                            subject.add_child(child = create_node)
                            assert_equal child, subject.find_child { true }
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

