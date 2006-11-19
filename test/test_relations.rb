require 'test/unit'
require 'test_config'
require 'roby/relations'

require 'roby/task'
require 'flexmock'

class TC_Relations < Test::Unit::TestCase
    include Roby
    include CommonTestBehaviour

    def test_definition
	klass = Class.new

	r1, r2 = nil
	space = Roby::RelationSpace(klass) do
	    r1 = relation :R1
	    r2 = relation :R2s, :child_name => :child, :parent_name => :parent
	end
	assert(Module === space)

	n = klass.new
	assert_equal(r2, space.constant('R2s'))
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
	    r1 = relation :R1
	    r2 = relation :Child, :parent_name => :parent
	end

	n1, n2, n3, n4 = 4.enum_for(:times).map { klass.new }
	n1.add_child_object(n2, r1)
	assert_nothing_raised { n1.add_child_object(n2, r1) }
	assert_raises(ArgumentError) { n1.add_child_object(n2, r1, true) }
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
		define_method(:added_child_object) { |to, type, info| mock.add(to, type, info) }
		define_method(:removed_child_object) { |to, type| mock.remove(to, type) }
	    end

	    klass = Class.new do
		include DirectedRelationSupport 
		include hooks
	    end
		
	    r1 = nil
	    Roby::RelationSpace(klass) { r1 = relation :R1 }

	    v1, v2 = klass.new, klass.new
	    mock.should_receive(:add).with(v2, r1, 1).once
	    mock.should_receive(:remove).with(v2, r1).once
	    v1.add_r1(v2, 1)
	    v1.remove_r1(v2)
	end
    end

    def test_subsets
	klass = Class.new { include DirectedRelationSupport }
	r1, r2 = nil
	Roby::RelationSpace(klass) do
	    r1 = relation :R1
	    r2 = relation :R2, :subsets => [r1]
	end
	assert_equal(r2, r1.parent)
	assert(! r1.subset?(r2))
	assert(r2.subset?(r1))

	n1, n2, n3 = 3.enum_for(:times).map { klass.new }
	n1.add_child_object(n2, r1)
	assert(n1.child_object?(n2, r2))
	n1.add_child_object(n3, r2)

	assert_equal([n2], n1.enum_for(:each_child_object, r1).to_a)
	assert_equal([n3, n2].to_set, n1.enum_for(:each_child_object, r2).to_set)
    end

end

