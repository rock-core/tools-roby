require 'test_config'
require 'roby/state/state'

class TC_State < Test::Unit::TestCase
    include Roby
    include CommonTestBehaviour

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

    def test_child_class
	klass = Class.new(ExtendedStruct)
	root = ExtendedStruct.new(klass)
	assert_equal(klass, root.child.class)
    end

    def test_stable
	s = ExtendedStruct.new
	s.other.attach
	
        s.stable!
	assert(s.stable?)
	assert(!s.other.stable?)
        assert_raises(NoMethodError) { s.test = 10 }
	assert(! s.respond_to?(:test=))
	assert_nothing_raised { s.other.test = 10 }

        s.stable!(true)
       	assert(s.stable?)
	assert(s.other.stable?)
	assert_raises(NoMethodError) { s.test = 10 }
        assert_raises(NoMethodError) { s.other.test = 10 }
	
        s.stable!(false, false)
       	assert(!s.stable?)
	assert(s.other.stable?)
        assert_nothing_raised { s.test = 10 }
        assert_raises(NoMethodError) { s.other.test = 10 }
	
        s.stable!(true, false)
       	assert(!s.stable?)
	assert(!s.other.stable?)
        assert_nothing_raised { s.test = 10 }
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
end
