$LOAD_PATH << File.join(File.dirname(__FILE__), '../lib')

require 'test/unit/testcase'
require 'roby/support'
require 'set'

class BaseClass
    class << self
        def self.extended_method
            true
        end
    end
    def extended_method
        true
    end
end

module BaseClassExtension
    def extended_method
        false
    end
    module ClassExtension
        def extended_method
            false
        end
    end
end

class TC_Utils < Test::Unit::TestCase
    def test_string_extensions
        assert_equal("DoCamelizeThat", "do_camelize_that".camelize)
    end

    def test_validate_options
        valid_options   = [ :a, :b, :c ]
        valid_test      = { :a => 1, :c => 2 }
        invalid_test    = { :k => nil }
        assert_nothing_raised(ArgumentError) { validate_options(valid_test, valid_options) }
        assert_raise(ArgumentError) { validate_options(invalid_test, valid_options) }

        check_array = validate_options( valid_test, valid_options )
        assert_equal( valid_test, check_array )
        check_empty_array = validate_options( nil, valid_options )
        assert_equal( {}, check_empty_array )

        default_values = { :a => nil, :b => nil, :c => nil, :d => 15 }
        new_options = nil
        assert_nothing_raised(ArgumentError) { new_options = validate_options(valid_test, default_values) }
        assert( new_options.has_key?(:d) )
        assert( !new_options.has_key?(:b) )
    end

    class A
        class_inherited_enumerable(:signature, :signatures) { Array.new }
        class_inherited_enumerable(:mapped, :map, :map => true) { Hash.new }
        attribute(:array_attribute) { Array.new }
    end
    class B < A
    end

    def test_attribute
        a = A.new
        assert_equal(a.array_attribute, a.array_attribute)
        a.array_attribute << 1
        assert_equal([1], a.array_attribute)
    end

    def test_inherited_enumerable
        # Test simple value (non-hash)
        [A, B].each do |klass|
            assert(klass.respond_to?(:each_signature))
            assert(klass.respond_to?(:signatures))
            assert(!klass.respond_to?(:has_signature?))
            assert(!klass.respond_to?(:find_signatures))

            assert(klass.respond_to?(:each_mapped))
            assert(klass.respond_to?(:map))
            assert(klass.respond_to?(:has_mapped?))
        end

        A.signatures << :in_a
        B.signatures << :in_b

        A.map[:a] = 10
        A.map[:b] = 20
        B.map[:a] = 15
        B.map[:c] = 25

        assert_equal([:in_a], A.enum_for(:each_signature).to_a)
        assert_equal([:in_b, :in_a], B.enum_for(:each_signature).to_a)
        assert_equal([10, 15].to_set, B.enum_for(:each_mapped, :a).to_set)
        assert_equal([10].to_set, A.enum_for(:each_mapped, :a).to_set)
        assert_equal([20].to_set, B.enum_for(:each_mapped, :b).to_set)
        assert_equal([[:a, 10], [:b, 20], [:a, 15], [:c, 25]].to_set, B.enum_for(:each_mapped).to_set)
    end

    def test_object_stats
        GC.disable
        Hash.new
        assert([Hash, 1], ObjectStats.profile { Hash.new }.collect { |klass, count| [klass, count] })
        assert([Hash, -1], ObjectStats.profile { GC.start }.collect { |klass, count| [klass, count] })
    end
end

