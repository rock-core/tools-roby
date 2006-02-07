require 'test_config'
require 'roby/state/state'

class TC_State < Test::Unit::TestCase
    include Roby
    def test_extendable_struct
        s = ExtendableStruct.new

        s.update do |s|
            s.value = true
            s.other.value = 1
        end

        assert( s.respond_to?(:value) )
        assert_equal( true, s.value )
        assert( s.other.respond_to?(:value) )
        assert_equal( 1, s.other.value )
        s.other.value = 42
        assert_equal( 42, s.other.value )

        s.stable!
        assert_raises(NoMethodError) { s.test = 10 }

        s.stable!(true)
        assert_raises(NoMethodError) { s.other.test = 10 }
    end
    
end
