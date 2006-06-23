$LOAD_PATH << File.join(File.dirname(__FILE__), '../lib')

require 'test/unit'
require 'roby/support'
require 'set'
require 'flexmock'

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
    def test_super_idiom
	base = Class.new do
	    attr_reader :base
	    def initialize
		super if defined? super
		@base = true
	    end
	end
	assert_nothing_raised { base.new }

	derived = Class.new(base) do
	    attr_reader :derived
	    def initialize
		super if defined? super
		@derived = true
	    end
	end
	obj = nil
	assert_nothing_raised { obj = derived.new }
	assert( obj.base )
	assert( obj.derived )

	mod = Module.new do
	    attr_reader :module
	    def initialize
		super if defined? super
		@module = true
	    end
	end
	obj = nil
	base.include mod

	assert_nothing_raised { obj = derived.new }
	assert( obj.base )
	assert( obj.module )
	assert( obj.derived )
    end
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

    def test_attr_enumerable
	klass = Class.new do
	    attr_enumerable(:mapped, :map) { Hash.new }
	end

	obj = klass.new
	obj.map[:a] = [10, 20]
	obj.map[:b] = 10
	assert_equal( [[:a, [10, 20]], [:b, 10]].to_set, obj.enum_for(:each_mapped).to_set )
	assert_equal( [10, 20], obj.enum_for(:each_mapped, :a).to_a )
    end

    def test_define_method_with_block
	FlexMock.use do |mock|
	    mock.should_receive(:called).once
	    block_obj = lambda { mock.called }
	    test_obj = self
	    method = lambda do |a, b, block|
		test_obj.assert_equal(a, 1)
		test_obj.assert_equal(b, 2)
		test_obj.assert_equal(block, block_obj)
		block_obj.call
	    end

	    klass = Class.new do
		define_method_with_block(:call, &method)
	    end
	    klass.new.call(1, 2, &block_obj)
	end
    end

    def test_keys_to_sym
	assert_equal({ :a => 10, :b => 20 }, { 'a' => 10, 'b' => 20 }.keys_to_sym)
    end
    def test_slice
	assert_equal({ :a => 10, :c => 30 }, { :a => 10, :b => 20, :c => 30 }.slice(:a, :c))
    end

    def test_inherited_enumerable
	a = Class.new do
	    class_inherited_enumerable(:signature, :signatures) { Array.new }
	    class_inherited_enumerable(:mapped, :map, :map => true) { Hash.new }
	end
	b = Class.new(a) do
	    class_inherited_enumerable(:only_in_child) { Hash.new }
	end

        [a, b].each do |klass|
            assert(klass.respond_to?(:each_signature))
            assert(klass.respond_to?(:signatures))
            assert(!klass.respond_to?(:has_signature?))
            assert(!klass.respond_to?(:find_signatures))

            assert(klass.respond_to?(:each_mapped))
            assert(klass.respond_to?(:map))
            assert(klass.respond_to?(:has_mapped?))
        end

	assert(!a.respond_to?(:only_in_child))
	assert(!a.respond_to?(:each_only_in_child))
	assert(b.respond_to?(:only_in_child))
	assert(b.respond_to?(:each_only_in_child))

        a.signatures << :in_a
        b.signatures << :in_b

        a.map[:a] = 10
        a.map[:b] = 20
        b.map[:a] = 15
        b.map[:c] = 25

        assert_equal([:in_a], a.enum_for(:each_signature).to_a)
        assert_equal([:in_b, :in_a], b.enum_for(:each_signature).to_a)
        assert_equal([10, 15].to_set, b.enum_for(:each_mapped, :a, false).to_set)
        assert_equal([15].to_set, b.enum_for(:each_mapped, :a, true).to_set)
        assert_equal([10].to_set, a.enum_for(:each_mapped, :a, false).to_set)
        assert_equal([20].to_set, b.enum_for(:each_mapped, :b).to_set)
        assert_equal([[:a, 10], [:b, 20], [:a, 15], [:c, 25]].to_set, b.enum_for(:each_mapped, nil, false).to_set)
        assert_equal([[:a, 15], [:b, 20], [:c, 25]].to_set, b.enum_for(:each_mapped, nil, true).to_set)

	# Test for singleton class support
	object = b.new
	assert(object.singleton_class.respond_to?(:signatures))
	object.singleton_class.signatures << :in_singleton
	assert_equal([:in_singleton], object.singleton_class.signatures)
        assert_equal([:in_singleton, :in_b, :in_a], object.singleton_class.enum_for(:each_signature).to_a)
    end

    def test_enum_uniq
        # Test the enum_uniq enumerator
        assert_equal([:a, :b, :c], [:a, :b, :a, :c].enum_uniq { |k| k }.to_a)
        assert_equal([:a, :b, :c], [:a, :b, :a, :c].enum_uniq.to_a)
	enum = [:a, :b, :a, :c].enum_uniq
	assert_equal(enum, enum.each)
	
        a, b, c, d = [1, 2], [1, 3], [2, 3], [3, 4]

        test = [a, b, c, d]
        assert_equal([a, c, d], test.enum_uniq { |x, y| x }.to_a)
        assert_equal([a, b, d], test.enum_uniq { |x, y| y }.to_a)

	klass = Class.new do
	    def initialize(base); @base = base end
	    def each(&iterator);  @base.each { |x, y| yield [x, y] } end
	    include Enumerable
	end
	test = klass.new(test)
        assert_equal([a, c, d], test.enum_uniq { |x, y| x }.to_a)
        assert_equal([a, b, d], test.enum_uniq { |x, y| y }.to_a)

        klass = Struct.new :x, :y
	test = test.map { |x, y| klass.new(x, y) }
        a, b, c, d = *test
        assert_equal([a, c, d], [a, b, c, d].enum_uniq { |v| v.x }.to_a)
        assert_equal([a, b, d], [a, b, c, d].enum_uniq { |v| v.y }.to_a)
    end

    def test_enum_sequence
	c1 = [:a, :b, :c]
	c2 = [:d, :e, :f]
	assert_equal([:a, :b, :c, :d, :e, :f], (c1.to_enum + c2.to_enum).to_a)
	assert_equal([:a, :b, :c, :d, :e, :f], [c1, c2].inject(null_enum) { |a, b| a + b }.to_a)
    end

    def test_address
	foo = Object.new
	foo.to_s =~ /#<Object:0x([0-9a-f]+)>/
	foo_address = $1
	assert_equal(foo_address, foo.address.to_s(16), "#{foo} #{foo.address} #{foo.object_id}")
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

    def test_object_stats
        GC.disable
        Hash.new
        assert([Hash, 1], ObjectStats.profile { Hash.new }.collect { |klass, count| [klass, count] })
        assert([Hash, -1], ObjectStats.profile { GC.start }.collect { |klass, count| [klass, count] })
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

    def test_object_stats
	assert( ObjectStats.profile { ObjectStats.count }.empty?, "Object allocation profile changed" )
	assert_equal({ Hash => 1 }, ObjectStats.profile { ObjectStats.count_by_class }, "Object allocation profile changed")
    end
end

