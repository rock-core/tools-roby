$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'

class TC_Relations < Test::Unit::TestCase
    include Roby::Test

    def test_definition
	klass = Class.new

	r1, r2 = nil
	space = Roby::RelationSpace(klass) do
	    r1 = relation :R1
	    r2 = relation :R2s, :child_name => :child, :parent_name => :parent
	end
	assert(Module === space)

        assert_equal(r1, r1.support.class_variable_get("@@__r_R1__"))

	n = klass.new
	assert_equal(r2, space.const_get('R2s'))
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
	assert_nothing_raised { n1.add_child_object(n2, r1, false) }
	assert_raises(ArgumentError) { n1.add_child_object(n2, r1, true) }
	n1.remove_child_object n2, r1
	assert_nothing_raised { n1.add_child_object(n2, r1) }
	assert_nothing_raised { n1.add_child_object(n2, r1, true) }
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
		include DirectedRelationSupport 
		include hooks
	    end
		
	    r1 = nil
	    Roby::RelationSpace(klass) { r1 = relation :R1 }

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
		include DirectedRelationSupport
		define_method(:added_child_object) do |child, relations, info|
		    super if defined? super
		    mock.hooked_addition(child, relations)
		end
		define_method(:removed_child_object) do |child, relations|
		    super if defined? super
		    mock.hooked_removal(child, relations)
		end
	    end

	    r1, r2 = nil
	    Roby::RelationSpace(klass) do
		r1 = relation :R1
		r2 = relation :R2, :subsets => [r1]
	    end
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
	klass = Class.new { include DirectedRelationSupport }
	graph = RelationGraph.new("test", :dag => true)

	v1, v2, v3 = (1..3).map { v = klass.new; graph.insert(v); v }
	graph.add_relation(v1, v2, nil)
	graph.add_relation(v2, v3, nil)
	assert_raises(CycleFoundError) { graph.add_relation(v3, v1, nil) }
    end

    def test_single_child
	klass = Class.new { include DirectedRelationSupport }

	r1 = nil
	Roby::RelationSpace(klass) { r1 = relation :R1, :single_child => true }
	parent = klass.new 
	child  = klass.new
	assert_equal(nil, parent.r1)
	parent.add_r1(child)
	assert_equal(child, parent.r1)
	parent.remove_r1(child)
	assert_equal(nil, parent.r1)
    end
end

