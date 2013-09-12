$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'

describe Roby::EventRelationGraph do
    attr_reader :event_m, :task_m, :space, :r
    attr_reader :ta, :ea, :tb, :eb

    before do
	@event_m = Class.new do
            attr_accessor :task
            def initialize(task)
                @task = task
            end
            include Roby::DirectedRelationSupport
        end
        @task_m = Class.new do
            include Roby::DirectedRelationSupport
        end
	@space = Roby::RelationSpace(event_m)
        space.default_graph_class = Roby::EventRelationGraph
        @r = space.relation :R, :child_name => 'child', :noinfo => true

        @ta = task_m.new
        @ea = event_m.new(ta)
        @tb = task_m.new
        @eb = event_m.new(tb)
    end

    describe "#related_tasks?" do
        it "should return false for new vertices" do
            assert(!r.related_tasks?(ta, tb))
        end

        it "should return true if an edge is added between two events" do
            ea.add_child(eb)
            assert(r.related_tasks?(ta, tb))
        end

        it "should return false if the edge is removed" do
            ea.add_child(eb)
            ea.remove_child(eb)
            assert(!r.related_tasks?(ta, tb))
        end

        it "should not return false if an edge is removed while another still exists on the sink" do
            ec = event_m.new(tb)
            ea.add_child(eb)
            ea.add_child(ec)
            ea.remove_child(eb)
            assert(r.related_tasks?(ta, tb))
        end

        it "should not return false if an edge is removed while another still exists on the source" do
            ec = event_m.new(ta)
            ea.add_child(eb)
            ec.add_child(eb)
            ea.remove_child(eb)
            assert(r.related_tasks?(ta, tb))
        end

        it "should remove the task from the task_graph if all its events are cleared" do
            tc = task_m.new
            ec = event_m.new(tc)
            ea.add_child(eb)
            eb.add_child(ec)

            assert(r.task_graph.include?(ta))
            assert(r.task_graph.include?(tb))

            ea.clear_vertex
            assert(!r.task_graph.include?(ta))
            assert(r.task_graph.include?(tb))

            ec.clear_vertex
            assert(!r.task_graph.include?(tb))
            assert(!r.task_graph.include?(tc))
        end
    end
end

