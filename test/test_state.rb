$LOAD_PATH.unshift File.expand_path('..', File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/state/pos'
require 'flexmock'

class TC_State < Test::Unit::TestCase
    include Roby::Test

    def test_openstruct_behavior
	s = ExtendedStruct.new
	assert( s.respond_to?(:value=) )
        assert( ! s.respond_to?(:value) )
	s.value = 42
        assert( s.respond_to?(:value) )
	assert_equal(42, s.value)
    end

    def test_update
	s = ExtendedStruct.new
	s.value.update { |v| v.test = 10 }
	assert_equal(10, s.value.test)

	s.value { |v| v.test = 10 }
	assert_equal(10, s.value.test)
    end

    def test_attach
	s = ExtendedStruct.new
	child = s.child
	assert_not_equal(child, s.child)
	child = s.child
	child.send(:attach)
	assert_equal(child, s.child)
	
	s = ExtendedStruct.new
	child = s.child
	assert_equal([s, 'child'], child.send(:attach_as))
	s.child = 10
	# child should NOT attach itself to s 
	assert_equal(10, s.child)
	assert( !child.send(:attach_as) )

	child.test = 20
	assert_not_equal(child, s.child)
	assert_equal(10, s.child)
    end

    def test_delete
	r = ExtendedStruct.new
	assert_raises(ArgumentError) { r.delete }

	# Check handling of pending children
	child = r.child
	child.delete
	child.value = 10
	assert(!r.child?)

	child = r.child
	r.delete(:child)
	child.value = 10
	assert(!r.child?)

	# Check handling of attached children
	r.child.value = 10
	assert(r.child?)
	r.delete(:child)
	assert(!r.child?)

	r.child.value = 10
	assert(r.child?)
	r.child.delete
	assert(!r.child?)

	# Check handling of aliases
	r.child.value = 10
	r.alias(:child, :aliased_child)
	assert(r.aliased_child?)
	r.delete(:aliased_child)
	assert(!r.aliased_child?)

	# Check handling of aliased-to members
	r.child.value = 10
	r.alias(:child, :aliased_child)
	assert(r.aliased_child?)
	r.child.delete
	assert(!r.aliased_child?)
	assert(!r.child?)
    end

    def test_empty
	r = ExtendedStruct.new
	c = r.child
	assert(r.empty?)
	r.child = 10
	assert(!r.empty?)
	r.delete(:child)
	assert(r.empty?)
    end

    def test_child_class
	klass = Class.new(ExtendedStruct)
	root = ExtendedStruct.new(klass)
	assert_equal(klass, root.child.class)
    end

    def test_export
	s = StateSpace.new
	s.pos.x   = 42
	s.speed.x = 0

	obj = Marshal.load(Marshal.dump(s))
	assert(!obj.respond_to?(:pos))
	assert(!obj.respond_to?(:speed))

	s.export :pos
	obj = Marshal.load(Marshal.dump(s))
	assert(obj.respond_to?(:pos))
	assert(!obj.respond_to?(:speed))
	assert_equal(42, obj.pos.x)

	s.export :speed
	obj = Marshal.load(Marshal.dump(s))
	assert(obj.respond_to?(:pos))
	assert(obj.respond_to?(:speed))
	assert_equal(42, obj.pos.x)
	assert_equal(0, obj.speed.x)
    end

    def test_stable
	s = ExtendedStruct.new
	s.other.attach
	
        s.stable!
	assert(s.stable?)
	assert(!s.other.stable?)
        assert_raises(NoMethodError) { s.test }
        assert_raises(NoMethodError) { s.test = 10 }
	assert(! s.respond_to?(:test=))
	assert_nothing_raised { s.other.test }
	assert_nothing_raised { s.other.test = 10 }

        s.stable!(true)
       	assert(s.stable?)
	assert_raises(NoMethodError) { s.test }
	assert_raises(NoMethodError) { s.test = 10 }
	assert(s.other.stable?)
	assert_raises(NoMethodError) { s.other.another_test }
	assert_nothing_raised { s.other.test }
        assert_raises(NoMethodError) { s.other.test = 10 }
	
        s.stable!(false, false)
       	assert(!s.stable?)
        assert_nothing_raised { s.test }
        assert_nothing_raised { s.test = 10 }
	assert(s.other.stable?)
	assert_raises(NoMethodError) { s.other.another_test }
	assert_nothing_raised { s.other.test }
        assert_raises(NoMethodError) { s.other.test = 10 }
	
        s.stable!(true, false)
       	assert(!s.stable?)
	assert(!s.other.stable?)
        assert_nothing_raised { s.test }
        assert_nothing_raised { s.test = 10 }
	assert_nothing_raised { s.other.test }
        assert_nothing_raised { s.other.test = 10 }
    end

    def test_filter
	s = ExtendedStruct.new
	s.filter(:test) { |v| Integer === v }
	assert_raises(ArgumentError) { s.test = "10" }
	assert_nothing_raised { s.test = 10 }
    end

    def test_alias
	s = ExtendedStruct.new
	s.value = 42
	s.alias(:value, :test)
	assert( s.respond_to?(:test) )
	assert_equal(42, s.value)
	assert_equal(42, s.test)
	s.value = Time.now
	assert_equal(s.test, s.value)

	# Test alias detach
	s.test = 10
	s.value = 42
	assert_equal(10, s.test)
    end

    def test_change_notification
	s = ExtendedStruct.new
	FlexMock.use do |mock|
	    s.on(:value) { |v| mock.updated(v) }
	    mock.should_receive(:updated).with(42).once
	    s.value = 42

	    s.on(:substruct) { |v| mock.updated_substruct(v.value) }
	    mock.should_receive(:updated_substruct).with(24).once.ordered
	    mock.should_receive(:updated_substruct).with(42).once.ordered
	    s.substruct.value = 24
	    s.substruct.value = 42
	end
    end

    def test_predicate
	s = ExtendedStruct.new
	s.a = false
	s.b = 1
	assert(!s.foobar?)
	assert(!s.a?)
	assert(s.b?)
    end

    def test_marshalling
	s = ExtendedStruct.new
	s.value = 42
	s.substruct.value = 24
	s.invalid = Proc.new {}

	s.on(:substruct) {}
	s.filter(:value) { |v| Numeric === v }

	str = nil
	assert_nothing_raised { str = Marshal.dump(s) }
	assert_nothing_raised { s = Marshal.load(str) }
	assert_equal(42, s.value)
	assert_equal(24, s.substruct.value)
	assert(!s.respond_to?(:invalid))
    end

    def test_forbidden_names
	s = ExtendedStruct.new
	assert_raises(NoMethodError) { s.each_blah }
	assert_raises(NoMethodError) { s.enum_blah }
	assert_raises(NoMethodError) { s.to_blah }
    end

    def test_pos_euler3d
	p = Pos::Euler3D.new(30)
	assert_equal(30, p.x)
	assert_equal(0, p.y)
	assert_equal(0, p.z)

	assert_equal(10, p.distance(30, 10))
	assert_equal(0, p.distance(p))
    end
end

