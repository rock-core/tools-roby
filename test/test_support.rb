require 'test_config'
require 'set'
require 'flexmock'

require 'roby/support'

class TC_Utils < Test::Unit::TestCase
    include RobyTestCommon

    def test_define_under
	mod = Module.new
	new_mod = mod.define_under(:Foo) { Module.new }
	assert_equal(new_mod, mod.define_under(:Foo) { flunk("block called in #define_under") })
    end

    def test_thread_server
	FlexMock.use do |mock|
	    server = ThreadServer.new(mock)
	    mock.should_receive(:call).once
	    server.call
	    server.quit!
	end

	FlexMock.use do |mock|
	    block = lambda { mock.call(1, block) }
	    class << block
		alias :__call__ :call
		def call(*args, &block)
		    @called = true
		    __call__(*args, &block)
		end
		def called?; @called end
	    end
		
	    t = Thread.new do
		while !block.called?
		    sleep(0.1)
		    Thread.current.process_events
		end
	    end

	    mock.should_receive(:call).with(1, block).once
	    t.send_to(block, :call, 1, &block)
	    t.join
	end
    end
end

