$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/self'
require 'flexmock'

class TC_EnsuredEvent < Test::Unit::TestCase
    include Roby::SelfTest

    def test_ensure
	setup = lambda do |mock|
	    e1, e2 = EventGenerator.new(true), Roby::EventGenerator.new(true)
	    plan.add [e1, e2]
	    e1.ensure e2
	    e1.on { |ev| mock.e1 }
	    e2.on { |ev| mock.e2 }
	    [e1, e2]
	end
	FlexMock.use do |mock|
	    e1, e2 = setup[mock]
	    mock.should_receive(:e2).ordered.once
	    mock.should_receive(:e1).ordered.once
	    e1.call(nil)
	end
	FlexMock.use do |mock|
	    e1, e2 = setup[mock]
	    mock.should_receive(:e1).never
	    mock.should_receive(:e2).once
	    e2.call(nil)
	end
	FlexMock.use do |mock|
	    e1, e2 = setup[mock]
	    mock.should_receive(:e2).ordered.once
	    mock.should_receive(:e1).ordered.once
	    e2.call(nil)
	    e1.call(nil)
	end
    end
end

