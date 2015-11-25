require 'roby/test/self'

class TC_Relations < Minitest::Test
    def test_definition
	klass = Class.new

	r1, r2 = nil
	space = Roby::RelationSpace(klass)
        r1 = space.relation :R1
        r1.class::Extension.module_eval do
            def specific_relation_method
            end
        end
        r2 = space.relation :R2s, child_name: :child, parent_name: :parent
	assert(Module === space)

	n = klass.new
	assert_equal(r2, space.constant('R2s'))
        assert(r2.embeds_info?)
	assert( n.respond_to?(:each_child) )
	assert( n.respond_to?(:add_child) )
	assert( n.respond_to?(:remove_child) )
	assert( n.respond_to?(:each_parent) )
	assert( n.respond_to?(:add_r1) )
	assert( n.respond_to?(:add_child) )
	assert( n.respond_to?(:specific_relation_method) )
    end

    def test_relation_info
	klass = Class.new { include Roby::Relations::DirectedRelationSupport }

	space = Roby::RelationSpace(klass)
        r2 = space.relation :R2
        r1 = space.relation :R1, subsets: [r2]
        assert(r1.embeds_info?)
        assert(r2.embeds_info?)

        r3 = space.relation :R3, noinfo: true
        r1.superset_of r3
        assert(!r3.embeds_info?)

	n1, n2 = 2.enum_for(:times).map { klass.new }
	n1.add_child_object(n2, r2)
        assert_equal(nil, n1[n2, r2])
        # Updating from nil to non-nil is allowed
	n1.add_child_object(n2, r2, false)
        assert_equal(false, n1[n2, r2])
        # But changing a non-nil value is not allowed
        assert_raises(ArgumentError) { n1.add_child_object(n2, r2, true) }

        def r2.merge_info(from, to, old, new)
            2
        end
        # Changing a non-nil value should yield the return value of merge_info
        n1.add_child_object(n2, r2, true)
        assert_equal 2, n1[n2, r2]
    end

    def test_relation_each_edge
	klass = Class.new { include Roby::Relations::DirectedRelationSupport }
	space = Roby::RelationSpace(klass)

        r1 = space.relation :R1

	n1, n2 = 2.enum_for(:times).map { klass.new }
	n1.add_child_object(n2, r1)

        assert_equal([ [n1, n2, nil] ], r1.enum_for(:each_edge).to_a )
    end

    def test_relation_info_in_subgraphs
	klass = Class.new { include Roby::Relations::DirectedRelationSupport }
	space = Roby::RelationSpace(klass)
        r2 = space.relation :R2
        r1 = space.relation :R1, subsets: [r2]

	n1, n2 = 2.enum_for(:times).map { klass.new }
        n1.add_child_object(n2, r2, obj = Hash.new)
        assert_equal(obj, n1[n2, r2])
        assert_equal(nil, n1[n2, r1])
        n1.add_child_object(n2, r1, other_obj = Hash.new)
        assert_equal(obj, n1[n2, r2])
        assert_equal(other_obj, n1[n2, r1])

        n1.remove_child_object(n2, r2)

        # Check that it works as well if we are updating a nil value
        n1.add_child_object(n2, r2, nil)
        n1.add_child_object(n2, r2, obj = Hash.new)
        assert_equal(obj, n1[n2, r2])
        assert_equal(nil, n1[n2, r1])
        n1.add_child_object(n2, r1, other_obj = Hash.new)
        assert_equal(obj, n1[n2, r2])
        assert_equal(other_obj, n1[n2, r1])
    end

    def test_add_remove_relations
	klass = Class.new { include Roby::Relations::DirectedRelationSupport }

	r1, r2 = nil
	space = Roby::RelationSpace(klass)
        r1 = space.relation :R1
        r2 = space.relation :Child, parent_name: :parent

	n1, n2, n3, n4 = 4.enum_for(:times).map { klass.new }
	n1.add_child_object(n2, r1, true)
	assert_equal([n2], n1.child_objects(r1).to_a)
	assert_equal([n1], n2.parent_objects(r1).to_a)

	assert( n1.child_object?(n2) )
	assert( n1.child_object?(n2, r1) )
	assert( !n1.child_object?(n2, r2) )
	assert( n2.parent_object?(n1) )
	assert( n2.parent_object?(n1, r1) )
	assert( !n2.parent_object?(n1, r2) )
	assert_equal( [n1], n2.enum_for(:each_parent_object).to_a )

	n1.add_r1(n3)
	n2.add_child(n4)
	
	assert( n1.child_object?(n2) )
	assert( n1.child_object?(n2, r1) )
	assert( !n1.child_object?(n2, r2) )
	assert( n2.parent_object?(n1) )
	assert( n2.parent_object?(n1, r1) )
	assert( !n2.parent_object?(n1, r2) )
	assert_equal( [], n1.enum_for(:each_parent_object).to_a )
	assert_equal( [], n3.enum_for(:each_child_object).to_a )
	assert_equal( [n2, n3].to_set, n1.enum_for(:each_child_object).to_set )

	assert( n2.related_object?(n1) )
	assert( n2.related_object?(n4) )

	n2.remove_child_object(n4, r2)
	assert(! n2.child_object?(n4) )
	assert(! n4.parent_object?(n2) )

	n1.remove_children(r2)
	assert( n1.child_object?(n2) )
	assert( !n1.child_object?(n4) )
	assert( !n4.parent_object?(n1) )

	n1.remove_child_object(n2)
	assert( !n1.child_object?(n2) )
	assert( !n2.parent_object?(n1) )

    end

    def test_hooks
	FlexMock.use do |mock|
	    hooks = Module.new do
		define_method(:added_child_object) { |to, relations, info| mock.add(to, relations, info) }
		define_method(:removed_child_object) { |to, relations| mock.remove(to, relations) }
	    end

	    klass = Class.new do
		include Roby::Relations::DirectedRelationSupport 
		include hooks
	    end
		
	    r1 = nil
	    space = Roby::RelationSpace(klass)
            r1 = space.relation :R1

	    v1, v2 = klass.new, klass.new
	    mock.should_receive(:add).with(v2, [r1], 1).once
	    mock.should_receive(:remove).with(v2, [r1]).once
	    v1.add_r1(v2, 1)
	    v1.remove_r1(v2)
	end
    end

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

    def test_single_child
	klass = Class.new { include Roby::Relations::DirectedRelationSupport }

	r1 = nil
	space = Roby::RelationSpace(klass)
        add_child_called = false
        remove_child_called = false
        r1 = space.relation :R1, single_child: true
        r1.class::Extension.module_eval do
            define_method(:added_r1) { |*args| add_child_called = true }
            define_method(:removed_r1) { |*args| remove_child_called = true }
        end

	parent = klass.new 
	child  = klass.new
	assert_equal(nil, parent.r1)
	parent.add_r1(child)
	assert_equal(child, parent.r1)
	parent.remove_r1(child)
	assert_equal(nil, parent.r1)

        assert(add_child_called)
        assert(remove_child_called)
    end

    def test_relations
	klass = Class.new { include Roby::Relations::DirectedRelationSupport }
	space = Roby::RelationSpace(klass)
        r1 = space.relation :R1
        assert_equal [r1], space.relations
    end

    def test_child_enumeration_without_info
	klass = Class.new { include Roby::Relations::DirectedRelationSupport }
	space = Roby::RelationSpace(klass)
        r1 = space.relation :R1, child_name: 'child', noinfo: true

        v1, v2 = klass.new, klass.new
        v1.add_child(v2, test: true)

        assert_equal([v2], v1.each_child.to_a)
    end
    def test_child_enumeration_with_info
	klass = Class.new { include Roby::Relations::DirectedRelationSupport }
	space = Roby::RelationSpace(klass)
        r1 = space.relation :R1, child_name: 'child'

        v1, v2 = klass.new, klass.new
        v1.add_child(v2, test: true)

        assert_equal([[v2, {test: true}]], v1.each_child.to_a)
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

