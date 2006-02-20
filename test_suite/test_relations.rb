require 'test/unit'
require 'test_config'
require 'roby/task'
require 'roby/relations'
require 'roby/relations/hierarchy'
require 'mockups/tasks'

class TC_Relations < Test::Unit::TestCase
    include Roby
    def test_hierarchy
        a = EmptyTask.new
        b = EmptyTask.new
        c = EmptyTask.new

        a.realized_by b
        assert( !a.realizes?(b) )
        assert( b.realizes?(a) )
        assert( a.realized_by?(b) )
        assert( !b.realized_by?(a) )

        assert_equal([],  a.enum_for(:each_parent).to_a)
        assert_equal([b], a.enum_for(:each_child).to_a)
        assert_equal([a], b.enum_for(:each_parent).to_a)
        assert_equal([],  c.enum_for(:each_child).to_a)
        assert_equal(b.enum_for(:each_relation).to_a, a.enum_for(:each_relation).to_a )

        b.realized_by c
        assert_equal([b, c], a.enum_for(:each_child, true).to_a)
        assert_equal([c], b.enum_for(:each_child).to_a)
        assert_equal([b, c].to_set, a.first_children.to_set)
        assert_equal([c], b.first_children)

        a.remove_relation(TaskStructure::Hierarchy, b)
        assert( !a.realizes?(b) )
        assert( !b.realizes?(a) )
        assert( !a.realized_by?(b) )
        assert( !b.realized_by?(a) )

        assert_equal([], a.enum_for(:each_parent).to_a)
        assert_equal([], a.enum_for(:each_child).to_a)
        assert_equal([], b.enum_for(:each_parent).to_a)
        assert_equal([c], b.enum_for(:each_child).to_a)
        assert_equal([], a.enum_for(:each_relation).to_a )
        assert_equal(b.enum_for(:each_relation).to_a, c.enum_for(:each_relation).to_a )
    end
end

