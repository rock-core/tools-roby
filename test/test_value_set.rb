require 'roby/test/self'
require 'value_set'

class TC_ValueSet < Minitest::Test
    def test_value_set
        a = [1, 3, 3, 4, 6, 8].to_value_set
        b = [1, 2, 4, 3, 11, 11].to_value_set
        assert_equal(5, a.size)
        assert_equal([1, 3, 4, 6, 8], a.to_a)
        assert(a.include?(1))
        assert(a.include_all?([4, 1, 8].to_value_set))
        assert(!a.include_all?(b))

        assert(a.intersects?(b))
        assert(b.intersects?(a))
        assert(!a.intersects?([2, 9, 12].to_value_set))

        assert(a.object_id == a.to_value_set.object_id)

        assert_equal([1, 2, 3, 4, 6, 8, 11], (a.union(b)).to_a)
        assert_equal([1, 3, 4], (a.intersection(b)).to_a)
        assert_equal([6, 8], (a.difference(b)).to_a)
        assert(! (a == :bla)) # check #== behaves correctly with a non-enumerable

        a.delete(1)
        assert(! a.include?(1))
        a.merge(b);
        assert_equal([1, 2, 3, 4, 6, 8, 11].to_value_set, a)

        assert([].to_value_set.empty?)

        assert([1, 2, 4, 3].to_value_set.clear.empty?)

        assert_equal([1,3,5].to_value_set, [1, 2, 3, 4, 5, 6].to_value_set.delete_if { |v| v % 2 == 0 })
    end

    def test_value_set_hash
        a = [(obj = Object.new), 3, 4, [(obj2 = Object.new), Hash.new]].to_value_set
        b = [obj, 3, 4, [obj2, Hash.new]].to_value_set
        assert_equal a.hash, b.hash
    end

    def test_value_set_to_s
        obj = ValueSet.new
        obj << 1
        obj << 2
        assert(obj.to_s =~ /\{(.*)\}/)
        values = $1.split(", ")
        assert_equal(["1", "2"].to_set, values.to_set)

        obj << obj
        assert(obj.to_s =~ /^(.+)\{(.*)\}>$/)

        base_s = $1
        values = $2.split(", ")
        assert_equal(["1", "2", "#{base_s}...>"].to_set, values.to_set)
    end

    def test_value_set_add
        a = [1, 3, 3, 4, 6, 8].to_value_set
        assert_same a, a.add(10)
        assert a.include?(10)
    end

    def test_value_set_substract
        a = [1, 3, 3, 4, 6, 8].to_value_set
        a.substract([3,4])
        assert_equal [1, 6, 8].to_value_set, a
    end
end
