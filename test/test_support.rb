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

    def test_enum_graph
	node = Class.new do
	    def initialize(id, children)
		@id, @children = id, children
	    end
	    def each_child(&iterator)
		@children.each(&iterator)
	    end
	    def pretty_print(pp)
		pp.text @id.to_s
	    end
	end
	bottom	= node.new(:bottom, [])
	left	= node.new(:left, [ bottom ])
	right	= node.new(:right, [ bottom, left ])
	root	= node.new(:root, [ left, right ])

	as_array = []
	root.enum_dfs(:each_child) { |a| as_array << a }
	assert_equal(root.enum_dfs(:each_child).to_a, as_array)
	assert_equal([bottom, left, right], root.enum_dfs(:each_child).to_a)
	assert_equal([[left, bottom], [root, left], [right, bottom], [right, left], [root, right]], root.enum_dfs(:each_child).enum_for(:each_edge).to_a)

	as_array = []
	root.enum_bfs(:each_child) { |a| as_array << a }
	assert_equal(as_array, root.enum_bfs(:each_child).to_a)
	assert_equal([left, right, bottom], root.enum_bfs(:each_child).to_a)
	assert_equal([[root, left], [root, right], [left, bottom], [right, bottom], [right, left]], root.enum_bfs(:each_child).enum_for(:each_edge).to_a)

	test = [bottom, right]
	class << test
	    alias :each_child :each
	end
	assert_equal([bottom], test.enum_leafs(:each_child).to_a)
	
	# Check for cycle handling
	right = [ nil ]
	left = [ nil ]
	root = [ left, right ]
	right[0] = root
	left[0] = root
	[root, left, right].each do |a| 
	    def a.hash; object_id end
	end
	assert_equal([left, right].map { |a| a.object_id }, root.enum_bfs(:each).map { |a| a.object_id })
	assert_equal([left, right].map { |a| a.object_id }, root.enum_dfs(:each).map { |a| a.object_id })
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

