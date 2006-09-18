$LOAD_PATH << File.join(File.dirname(__FILE__), '../lib')

require 'test/unit'
require 'roby/support'
require 'set'
require 'flexmock'

class TC_Utils < Test::Unit::TestCase
    def test_attribute
	a = Class.new do
	    attribute(:array_attribute) { Array.new }
	end.new
        assert_equal(a.array_attribute, a.array_attribute)
        a.array_attribute << 1
        assert_equal([1], a.array_attribute)

	b = Class.new do
	    class_attribute :a => 10
	end
	assert(b.respond_to?(:a))
	assert_equal(10, b.a)

	c = Class.new(b) do
	    class_attribute :c => 20
	end
	assert(!b.respond_to?(:c))
    end

    def test_keys_to_sym
	assert_equal({ :a => 10, :b => 20 }, { 'a' => 10, 'b' => 20 }.keys_to_sym)
    end
    def test_slice
	assert_equal({ :a => 10, :c => 30 }, { :a => 10, :b => 20, :c => 30 }.slice(:a, :c))
    end
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

