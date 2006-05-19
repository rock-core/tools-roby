require 'test/unit'
require 'test_config'
require 'roby/relations'

require 'roby/task'
require 'flexmock'

class TC_Relations < Test::Unit::TestCase
    include Roby

    def test_directed_relation_definition
	klass = Class.new { include DirectedRelationSupport }

	r1, r2 = nil
	Roby::RelationSpace(klass) do
	    r1 = relation :r1

	    r2 = relation :child do
		module_name :R2s
		parent_enumerator :parent
	    end
	end

	assert_equal(r1, r1.relation_type)

	n = klass.new
	assert( n.respond_to?(:each_child) )
	assert( n.respond_to?(:add_child) )
	assert( n.respond_to?(:remove_child) )
	assert( n.respond_to?(:each_parent) )
	assert( n.respond_to?(:add_r1) )
	assert( n.respond_to?(:add_child) )
    end

    def test_directed_relation
	klass = Class.new { include DirectedRelationSupport }

	r1, r2 = nil
	Roby::RelationSpace(klass) do
	    r1 = relation :r1

	    r2 = relation :child do
		module_name :R1s
		parent_enumerator :parent
	    end
	end

	n1, n2, n3, n4 = 4.enum_for(:times).map { klass.new }
	n1.add_child_object(n2, r1)
	assert( n1.child_object?(n2) )
	assert( n1.child_object?(n2, r1) )
	assert( !n1.child_object?(n2, r2) )
	assert( n2.parent_object?(n1) )
	assert( n2.parent_object?(n1, r1) )
	assert( !n2.parent_object?(n1, r2) )
	assert_equal( [n1], n2.enum_for(:each_parent_object).to_a )

	n1.add_child(n3)
	n2.add_r1(n4)
	
	assert( n1.child_object?(n2) )
	assert( n1.child_object?(n2, r1) )
	assert( !n1.child_object?(n2, r2) )
	assert( n2.parent_object?(n1) )
	assert( n2.parent_object?(n1, r1) )
	assert( !n2.parent_object?(n1, r2) )
	assert_equal( [], n1.enum_for(:each_parent_object).to_a )
	assert_equal( [], n3.enum_for(:each_child_object).to_a )
	assert_equal( [n2, n3].to_set, n1.enum_for(:each_child_object).to_set )
	assert_equal( [n2].to_a, n1.enum_for(:each_child_object, r1).to_a )

	assert( n2.related_object?(n1) )
	assert( n2.related_object?(n4) )

	assert_equal( [[r1, n1, n2, nil], [r2, n1, n3, nil]].to_set, n1.enum_for(:each_relation).to_set )
	assert_equal( [[r1, n2, n4, nil]], n2.enum_for(:each_relation, true).to_a )
	assert_equal( [[r1, n1, n2, nil], [r1, n2, n4, nil]].to_set, n2.enum_for(:each_relation).to_set )

	n2.remove_child_object(n4, r1)
	assert(! n2.child_object?(n4) )
	assert(! n4.parent_object?(n2) )

	n1.remove_child_object(nil, r2)
	assert( n1.child_object?(n2) )
	assert( !n1.child_object?(n3) )
	assert( !n3.parent_object?(n1) )

	n1.remove_child_object(n2, nil)
	assert( !n1.child_object?(n2) )
	assert( !n2.parent_object?(n1) )

	n1, n2 = 2.enum_for(:times).map { klass.new }
	n1.add_child_object(n2, r1)
	assert_equal(r1.enum_for(:each_relation, n1, false).to_a, r1.enum_for(:each_relation, n2, false).to_a)
	assert_equal(n1.enum_for(:each_relation).to_a, n2.enum_for(:each_relation).to_a)
    end

    def test_relation_enumerators
      	klass = Class.new { include DirectedRelationSupport }
	r1 = Module.new { include DirectedRelation }
	r2 = Module.new { 
	    include DirectedRelation 
	}
    end

    def test_subsets
	klass = Class.new { include DirectedRelationSupport }
	r1 = Module.new { include DirectedRelation }
	r2 = Module.new { 
	    include DirectedRelation 
	    superset_of r1
	}

	n1, n2, n3, n4 = 4.enum_for(:times).map { klass.new }
	n1.add_child_object(n2, r1)
	n1.add_child_object(n3, r2)

	assert_equal([n2], n1.enum_for(:each_child_object, r1).to_a)
	assert_equal([n3, n2].to_set, n1.enum_for(:each_child_object, r2).to_set)
    end

    def test_signals
	e1, e2 = Roby::EventGenerator.new(true), Roby::EventGenerator.new(true)

	e1.on e2
	assert( e1.child_object?( e2, Roby::EventStructure::Signals ))
	assert( e2.parent_object?( e1, Roby::EventStructure::Signals ))
    end

    def test_hierarchy
	klass = Class.new(Roby::Task) do
	    event(:start, :command => true)
	    event(:failed, :command => true)
	end

	t1, t2 = klass.new, klass.new
	t1.realized_by t2, :failure => :failed

	assert(t2.event(:failed).child_object?(t1.event(:aborted), Roby::EventStructure::Signals))

	FlexMock.use do |mock|
	    t1.on(:aborted) { mock.aborted }
	    mock.should_receive(:aborted).once

	    t1.start!
	    t2.start!
	    t2.failed!
	end
    end
end

