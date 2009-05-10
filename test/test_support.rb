$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/support'

class TC_Utils < Test::Unit::TestCase
    include Roby
    include Roby::Test

    def test_define_under
	mod = Module.new
	new_mod = mod.define_under(:Foo) { Module.new }
	assert_equal(new_mod, mod.define_under(:Foo) { flunk("block called in #define_under") })
    end
end

