$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/state'

class TC_ExtendedStruct < Test::Unit::TestCase
    include Roby::SelfTest

    class ExtendedStruct
        include Roby::ExtendedStruct

        def initialize(attach_to = nil, attach_name = nil)
            initialize_extended_struct(ExtendedStruct, attach_to, attach_name)
        end
    end

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

    def test_send
	s = ExtendedStruct.new
	s.x = 10
	assert_equal(10, s.send(:x))
    end

    def test_override_existing_method
        k = Class.new(ExtendedStruct) do
            def m(a, b, c); end
        end
        s = k.new
        s.m = 10
        assert_equal 10, s.m
        assert_equal 10, s.send(:m)
        assert s.m?
    end

    def test_get
	s = ExtendedStruct.new
        assert_equal nil, s.get(:x)
        s.x
        assert_equal nil, s.get(:x)
        s.x = 20
        assert_equal 20, s.get(:x)
    end

    def test_to_hash
	s = ExtendedStruct.new
	s.a = 10
	s.b.a = 10

	assert_equal({:a => 10, :b => { :a => 10 }}, s.to_hash)
	assert_equal({:a => 10, :b => s.b}, s.to_hash(false))
    end

    def test_pending_subfields_behaviour
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

    def test_field_attaches_when_read_from
        s = ExtendedStruct.new
        field = s.child
        assert !field.attached?
        field.test
        assert field.attached?
        assert_same(field, s.child)
    end

    def test_field_attaches_when_written_to
        s = ExtendedStruct.new
        field = s.child
        assert !field.attached?
        field.test = 10
        assert field.attached?
        assert_same(field, s.child)
    end
    
    def test_alias
	r = ExtendedStruct.new
        obj = Object.new
        r.child = obj
        r.alias(:child, :aliased_child)
        assert r.respond_to?(:aliased_child)
        assert r.aliased_child?
        assert_same obj, r.aliased_child

        obj = Object.new
        r.child = obj
        assert_same obj, r.aliased_child

        obj = Object.new
        r.aliased_child = obj
        assert_same obj, r.child
    end

    def test_delete_free_struct
	r = ExtendedStruct.new
	assert_raises(ArgumentError) { r.delete }
    end

    def test_delete_from_pending_child
	r = ExtendedStruct.new
	child = r.child
	child.delete
	child.value = 10
	assert(!r.child?)
    end

    def test_delete_specific_pending_child_from_parent
	r = ExtendedStruct.new
	child = r.child
	r.delete(:child)
	child.value = 10
	assert(!r.child?)
    end

    def test_delete_from_attached_child
	r = ExtendedStruct.new
	r.child.value = 10
	assert(r.child?)
	r.delete(:child)
	assert(!r.child?)
    end

    def test_delete_specific_attached_child_from_parent
	r = ExtendedStruct.new
	r.child.value = 10
	assert(r.child?)
	r.child.delete
	assert(!r.child?)
    end

    def test_delete_alias_from_parent
	r = ExtendedStruct.new
	r.child.value = 10
	r.alias(:child, :aliased_child)
	assert(r.aliased_child?)
	r.delete(:aliased_child)
	assert(!r.aliased_child?)
    end

    def test_delete_aliased_child_from_parent_deletes_the_alias
	r = ExtendedStruct.new
	r.child.value = 10
	r.alias(:child, :aliased_child)
	assert(r.aliased_child?)
	r.child.delete
	assert(!r.aliased_child?)
	assert(!r.child?)
    end

    def test_delete_from_attached_child_deletes_aliased_child
	r = ExtendedStruct.new
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
	s.filter(:test) do |v|
            Integer(v)
        end
	s.test = "10"
        assert_equal 10, s.test
    end

    def test_filter_can_call_stable
        s = ExtendedStruct.new
        s.filter(:test) do |v|
            result = ExtendedStruct.new
            result.value = v
            s.stable!
            result
        end
        s.test = 10
        assert s.stable?
        assert_kind_of ExtendedStruct, s.test
        assert_equal 10, s.test.value
    end

    def test_raising_filter_cancels_attachment
	s = ExtendedStruct.new
	s.filter(:test) do |v|
            Integer(v)
        end
        assert_raises(ArgumentError) { s.test = "a" }
        assert !s.test?
    end

    def test_raising_filter_cancels_update
	s = ExtendedStruct.new
        s.test = 10
	s.filter(:test) do |v|
            Integer(v)
        end
        assert_raises(ArgumentError) { s.test = "a" }
        assert s.test?
        assert_equal 10, s.test
    end

    def test_global_filter
	s = ExtendedStruct.new
	s.global_filter do |name, v|
            assert_equal 'test', name
            Integer(v)
        end
	s.test = "10"
        assert_equal 10, s.test
    end

    def test_global_filter_can_call_stable
        s = ExtendedStruct.new
	s.global_filter do |name, v|
            assert_equal 'test', name
            result = ExtendedStruct.new
            result.value = v
            s.stable!
            result
        end
        s.test = 10
        assert s.stable?
        assert_kind_of ExtendedStruct, s.test
        assert_equal 10, s.test.value
    end

    def test_raising_global_filter_cancels_attachment
	s = ExtendedStruct.new
	s.global_filter do |name, v|
            assert_equal 'test', name
            Integer(v)
        end
        assert_raises(ArgumentError) { s.test = "a" }
        assert !s.test?
    end

    def test_raising_global_filter_cancels_update
	s = ExtendedStruct.new
        s.test = 10
	s.global_filter do |name, v|
            assert_equal 'test', name
            Integer(v)
        end
        assert_raises(ArgumentError) { s.test = "a" }
        assert s.test?
        assert_equal 10, s.test
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
        s.unattached
	assert(!s.foobar?)
        assert(!s.unattached?)
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
	assert_nothing_raised { s.blato }
	assert_raises(NoMethodError) { s.enum_blah }
	assert_raises(NoMethodError) { s.to_blah }
    end

    def test_overrides_methods_that_are_not_protected
	s = ExtendedStruct.new
        def s.y(i); end
	assert_raises(ArgumentError) { s.y }
	s.y = 10
	assert_equal(10, s.y)
    end

    def test_existing_instance_methods_are_protected
        s = ExtendedStruct.new
        assert_raises(ArgumentError) { s.get = 10 }
    end

    def test_path
        s = ExtendedStruct.new
        assert_equal [], s.path
        s.pose.attach
        assert_equal ['pose'], s.pose.path
        s.pose.position.attach
        assert_equal ['pose', 'position'], s.pose.position.path
    end

    def test_does_not_catch_equality_operators
        s = ExtendedStruct.new
        assert_raises(NoMethodError) { s <= 10 }
    end
end


