$LOAD_PATH << File.join(File.dirname(__FILE__), '../lib')

require 'test/unit/testcase'
require 'roby/support'

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
        model_enumerator(:signature, :sig)

        @sig = [ :in_a ]
        def initialize
            @sig = [ :in_a_object ]
        end
    end
    class B < A
        @sig = [ :in_b ]
        def initialize
            @sig = [ :in_b_object ]
        end
    end

    def test_model_enumerator
        assert(A.respond_to?(:each_signature))
        assert(A.new.respond_to?(:each_signature))
        assert(A.respond_to?(:sig))
        assert(A.new.respond_to?(:sig))

        assert_equal([:in_a], A.enum_for(:each_signature).to_a)
        assert_equal([:in_b, :in_a], B.enum_for(:each_signature).to_a)

        a = A.new
        class << a
            @sig = [ :in_a_singleton ]
        end
        assert_equal([:in_a_object, :in_a_singleton, :in_a], a.enum_for(:each_signature).to_a)

        b = B.new
        class << b
            @sig = [ :in_b_singleton ]
        end
        assert_equal([:in_b_object, :in_b_singleton, :in_b, :in_a], b.enum_for(:each_signature).to_a)
    end
end

