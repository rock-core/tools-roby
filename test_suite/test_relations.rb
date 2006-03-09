require 'test/unit'
require 'test_config'
require 'roby/task'
require 'roby/relations'
require 'roby/relations/hierarchy'
require 'mockups/tasks'

class TC_Relations < Test::Unit::TestCase
    include Roby

    def test_relations
	klass = Class.new { include DirectedRelationSupport }
	r1 = Module.new { extend DirectedRelation }
	r2 = Module.new { extend DirectedRelation }

	n1, n2, n3, n4 = 4.enum_for(:times).map { klass.new }
	n1.add_child(n2, r1)
	n1.add_child(n3, r2)
	n2.add_child(n4, r1)
	
	assert( n1.child_object?(n2) )
	assert( n1.child_object?(n2, r1) )
	assert( !n1.child_object?(n2, r2) )
	assert_equal( [n2, n3].to_set, n1.enum_for(:each_child_object).to_set )
	assert_equal( [n2].to_set, n1.enum_for(:each_child_object, r1).to_set )

	assert( n2.parent_object?(n1) )
	assert( n2.parent_object?(n1, r1) )
	assert( !n2.parent_object?(n1, r2) )
	assert_equal( [n1], n2.enum_for(:each_parent_object).to_a )

	assert( n2.related_object?(n1) )
	assert( n2.related_object?(n4) )

	assert_equal( [[r1, n1, n2, nil], [r2, n1, n3, nil]].to_set, n1.enum_for(:each_relation).to_set )
	assert_equal( [[r1, n2, n4, nil]].to_set, n2.enum_for(:each_relation, true).to_set )
	assert_equal( [[r1, n1, n2, nil], [r1, n2, n4, nil]].to_set, n2.enum_for(:each_relation).to_set )

	n2.remove_child(n4, r1)
	assert(! n2.child_object?(n4) )
	assert(! n4.parent_object?(n2) )

	n1.remove_child(nil, r2)
	assert( n1.child_object?(n2) )
	assert( !n1.child_object?(n3) )
	assert( !n3.parent_object?(n1) )

	n1.remove_child(n2, nil)
	assert( !n1.child_object?(n2) )
	assert( !n2.parent_object?(n1) )
    end
    
    def test_hierarchy
        a = EmptyTask.new
        b = EmptyTask.new
        c = EmptyTask.new

        a.realized_by b
        assert( !a.realizes?(b) )
        assert( b.realizes?(a) )
        assert( a.realized_by?(b) )
        assert( !b.realized_by?(a) )

        assert_equal([],  a.enum_for(:each_parent).to_a)
        assert_equal([b], a.enum_for(:each_child).to_a.map { |x, _| x })
        assert_equal([a], b.enum_for(:each_parent).to_a)
        assert_equal([],  c.enum_for(:each_child).to_a)
        assert_equal(b.enum_for(:each_relation).to_a, a.enum_for(:each_relation).to_a )

        b.realized_by c
        assert_equal([c], b.enum_for(:each_child).to_a.map { |x, _| x })
        assert_equal([b, c].to_set, a.first_children.to_set)
        assert_equal([c], b.first_children)

        a.remove_child(b, TaskStructure::Hierarchy)
        assert( !a.realizes?(b) )
        assert( !b.realizes?(a) )
        assert( !a.realized_by?(b) )
        assert( !b.realized_by?(a) )

        assert_equal([], a.enum_for(:each_parent).to_a)
        assert_equal([], a.enum_for(:each_child).to_a)
        assert_equal([], b.enum_for(:each_parent).to_a)
        assert_equal([c], b.enum_for(:each_child).to_a)
        assert_equal([], a.enum_for(:each_relation).to_a )
        assert_equal(b.enum_for(:each_relation).to_a, c.enum_for(:each_relation).to_a )
    end
end

