$LOAD_PATH << File.join(File.dirname(__FILE__), '../lib')

require 'test/unit'
require 'roby/support'
require 'set'

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

    def test_inherited_enumerable
	a = Class.new do
	    class_inherited_enumerable(:signature, :signatures) { Array.new }
	    class_inherited_enumerable(:mapped, :map, :map => true) { Hash.new }
	end
	b = Class.new(a) do
	    class_inherited_enumerable(:only_in_child) { Hash.new }
	end

        # Test simple value (non-hash)
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
        assert_equal([10].to_set, a.enum_for(:each_mapped, :a).to_set)
        assert_equal([20].to_set, b.enum_for(:each_mapped, :b).to_set)
        assert_equal([[:a, 15], [:b, 20], [:c, 25]].to_set, b.enum_for(:each_mapped, nil, true).to_set)
        assert_equal([[:a, 10], [:b, 20], [:a, 15], [:c, 25]].to_set, b.enum_for(:each_mapped, nil, false).to_set)
    end

    def test_enum_uniq
	# Test the enum_uniq enumerator
	assert_equal([:a, :b, :c], [:a, :b, :a, :c].enum_uniq.to_a)

	klass = Struct.new :a, :b
	a, b, c, d = [[1, 2], [1, 3], [2, 3], [3, 4]].collect { |values| klass.new(*values) }
	assert_equal([a, c, d], [a, b, c, d].enum_uniq { |v| v.a }.to_a)
	assert_equal([a, b, d], [a, b, c, d].enum_uniq { |v| v.b }.to_a)
    end

    def test_enum_tree
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
	root.enum_dfs(:each_child) { |*a| as_array << a }
	assert_equal(root.enum_dfs(:each_child).to_a, as_array)
	assert_equal([[bottom, left], [left, root], [right, root]], root.enum_dfs(:each_child).to_a)

	# topological is broken for now
	#assert_equal([right, left, bottom], root.enum_bfs(:each_child).topological)
	as_array = []
	root.enum_bfs(:each_child) { |*a| as_array << a }
	assert_equal(root.enum_bfs(:each_child).to_a, as_array)
	assert_equal([[left, root], [right, root], [bottom, left]], root.enum_bfs(:each_child).to_a)
    end

    def test_object_stats
        GC.disable
        Hash.new
        assert([Hash, 1], ObjectStats.profile { Hash.new }.collect { |klass, count| [klass, count] })
        assert([Hash, -1], ObjectStats.profile { GC.start }.collect { |klass, count| [klass, count] })
    end

end

