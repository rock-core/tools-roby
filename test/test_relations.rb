
class TC_Relations < Minitest::Test
    def test_subsets
	FlexMock.use do |mock|
	    klass = Class.new do
		def initialize(index); @index = index end
		def to_s; "v#{@index.to_s}" end
		include Roby::Relations::DirectedRelationSupport
		define_method(:added_child_object) do |child, relations, info|
		    super(child, relations, info) if defined? super
		    mock.hooked_addition(child, relations)
		end
		define_method(:removed_child_object) do |child, relations|
		    super(child, relations) if defined? super
		    mock.hooked_removal(child, relations)
		end
	    end

	    r1, r2 = nil
	    space = Roby::RelationSpace(klass)
            r1 = space.relation :R1
            r2 = space.relation :R2, subsets: [r1]
	    assert_equal(r2, r1.parent)
	    assert(! r1.subset?(r2))
	    assert(r2.subset?(r1))
	    assert(!r1.root_relation?)
	    assert(r2.root_relation?)

	    n1, n2, n3 = (1..3).map do |i|
		klass.new(i)
	    end

	    mock.should_receive(:hooked_addition).with(n2, [r1, r2]).once
	    n1.add_child_object(n2, r1)
	    assert(n1.child_object?(n2, r2))

	    mock.should_receive(:hooked_addition).with(n3, [r2]).once
	    n1.add_child_object(n3, r2)
	    assert_equal([n2], n1.enum_for(:each_child_object, r1).to_a)
	    assert_equal([n3, n2].to_set, n1.enum_for(:each_child_object, r2).to_set)

	    mock.should_receive(:hooked_removal).with(n2, [r1, r2]).once
	    n1.remove_child_object(n2, r1)

	    mock.should_receive(:hooked_removal).with(n3, [r2]).once
	    n1.remove_child_object(n3, r2)
	end
    end

    def test_dag_checking
	klass = Class.new { include Roby::Relations::DirectedRelationSupport }
	graph = Relations::Graph.new("test", dag: true)

	v1, v2, v3 = (1..3).map { v = klass.new; graph.insert(v); v }
	graph.add_relation(v1, v2, nil)
	graph.add_relation(v2, v3, nil)
	assert_raises(Relations::CycleFoundError) { graph.add_relation(v3, v1, nil) }
    end

    def test_clear_relations
	klass = Class.new { include Roby::Relations::DirectedRelationSupport }
	space = Roby::RelationSpace(klass)
        r1 = space.relation :R1, child_name: 'child', noinfo: true
        r2 = space.relation :R2, child_name: 'child2', noinfo: true

        v = klass.new
        r1.insert(v)
        r2.insert(v)
        assert_equal [r1, r2].to_set, v.relations.to_set
        v.clear_relations
        assert_equal [], v.relations
    end

    def test_event_relation_graph
	klass = Class.new do
            attr_accessor :task
            def initialize(task)
                @task = task
            end
            include Roby::Relations::DirectedRelationSupport
        end
	space = Roby::RelationSpace(klass)
        space.default_graph_class = Relations::EventRelationGraph
        r = space.relation :R, child_name: 'child', noinfo: true

        ta = Object.new
        ea = klass.new(ta)
        tb = Object.new
        eb = klass.new(tb)

        assert(!r.related_tasks?(ta, tb))

        ea.add_child(eb)
        assert(r.related_tasks?(ta, tb))

        ea.remove_child(eb)
        assert(!r.related_tasks?(ta, tb))
        assert(r.task_graph.include?(ta))
        assert(r.task_graph.include?(tb))

        ea.clear_vertex
        eb.clear_vertex
        assert(!r.task_graph.include?(ta))
        assert(!r.task_graph.include?(tb))
    end
end

