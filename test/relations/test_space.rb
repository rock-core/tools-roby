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
            def create_node
                klass.new(graphs)
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

