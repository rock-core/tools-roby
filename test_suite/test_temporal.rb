require 'test/unit'
require 'test_config'
require 'roby/event'

class TC_Relations < Test::Unit::TestCase
    include Roby

    def test_until
	e1, e2, e3, e4 = 4.enum_for(:times).map { Roby::EventGenerator.new(true) }
	e1.on(e2)
	e2.on(e3)
	e3.until(e2).on(e4)

	e1.call(nil)
	assert( e3.happened? )
	assert( !e4.happened? )
    end
end


