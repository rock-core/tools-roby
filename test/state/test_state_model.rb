$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/state'

class TC_StateModel < Test::Unit::TestCase
    include Roby::SelfTest

    def test_export
	s = StateSpace.new
	s.pos.x   = 42
	s.speed.x = 0

	obj = Marshal.load(Marshal.dump(s))
	assert(obj.respond_to?(:pos))
	assert(obj.respond_to?(:speed))
	assert_equal(42, obj.pos.x)
	assert_equal(0, obj.speed.x)

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

        s.export_none
	obj = Marshal.load(Marshal.dump(s))
	assert(!obj.respond_to?(:pos))
	assert(!obj.respond_to?(:speed))
    end
end

