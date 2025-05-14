# frozen_string_literal: true

require "roby/test/self"
require "roby/state"

module Roby
    describe OpenStruct do
        describe "has_method?" do
            attr_reader :s

            before do
                @s = OpenStruct.new
                @s.other.attach
            end

            it "returns false for a non-existent method" do
                refute s.has_method?(:nonexistent)
            end

            it "returns false for the accessor methods of a member" do
                refute s.has_method?(:other)
                refute s.has_method?(:other?)
                refute s.has_method?(:other=)
            end

            it "returns true for a method from OpenStruct" do
                assert s.has_method?(:__get)
            end

            it "returns true for a singleton method" do
                def s.something; end
                assert s.has_method?(:something)
            end
        end

        describe "#respond_to?" do
            attr_reader :s

            before do
                @s = OpenStruct.new
                @s.other.attach
            end

            it "returns false if neither the field nor the method exist" do
                refute s.respond_to?(:does_not_exist)
            end

            it "returns true for setter method on non-existent names" do
                assert s.respond_to?(:something=)
            end

            it "returns true for question mark method on non-existent names" do
                assert s.respond_to?(:something?)
            end

            it "returns false for the question mark method on an existing method" do
                refute s.respond_to?(:__get?)
            end

            it "returns false for the setter method on an existing method" do
                refute s.respond_to?(:__get=)
            end

            it "returns true for an existing method" do
                assert s.respond_to?(:__get)
            end

            it "returns true for a getter method on an existing field" do
                assert s.respond_to?(:other)
            end

            it "returns true for presence method on an existing field" do
                assert s.respond_to?(:other)
            end
        end

        describe "non-stable structs" do
            describe "respond_to?" do
                attr_reader :s

                before do
                    @s = OpenStruct.new
                    @s.other.attach
                end

                it "returns true for '?'" do
                    assert @s.respond_to?(:somethiiiiing?)
                end
            end
        end

        describe "stable structs" do
            attr_reader :s

            before do
                @s = OpenStruct.new
                @s.other.attach
            end

            it "is not recursive by default" do
                s.stable!
                assert s.stable?
                refute s.other.stable?
            end

            it "lets access (read/write) to existing fields" do
                s.test = "something"
                s.stable!
                assert s.respond_to?(:test)
                assert s.respond_to?(:test=)
                assert s.respond_to?(:test?)

                assert_equal "something", s.test
                s.test = "else"
                assert_equal "else", s.test
            end

            it "does not allow creating a new field by attaching a pending child " \
               "via setting one of its fields" do
                unattached_child = OpenStruct.new
                unattached_child.test = 10
                unattached_child.link_to(s, "test")
                s.stable!

                assert_raises(OpenStruct::Stable) { unattached_child.test = 20 }
                refute unattached_child.attached?
                refute s.test?
                assert_equal 10, unattached_child.test
            end

            it "does not allow access to non-existing fields" do
                s.stable!
                refute s.respond_to?(:test)
                refute s.respond_to?(:test=)
                refute s.respond_to?(:test?)
                assert_raises(OpenStruct::Stable) { s.test }
                assert_raises(OpenStruct::Stable) { s.test = 10 }
            end

            it "may be applied recursively" do
                s.stable!(true)
                assert s.other.stable?
            end

            it "allows resetting the stable flag to false" do
                s.stable!(true)
                s.stable!(false, false)
                refute s.stable?
                assert s.other.stable?
            end

            it "allows resetting the stable flag to false, recursively" do
                s.stable!(true)
                s.stable!(true, false)
                refute s.stable?
                refute s.other.stable?
            end
        end
    end
end

class TC_OpenStruct < Minitest::Test
    def test_openstruct_behavior
        s = OpenStruct.new
        assert(s.respond_to?(:value=))
        assert(!s.respond_to?(:value))
        s.value = 42
        assert(s.respond_to?(:value))
        assert_equal(42, s.value)
    end

    def test_update
        s = OpenStruct.new
        s.value.update { |v| v.test = 10 }
        assert_equal(10, s.value.test)

        s.value { |v| v.test = 10 }
        assert_equal(10, s.value.test)
    end

    def test_send
        s = OpenStruct.new
        s.x = 10
        assert_equal(10, s.send(:x))
    end

    def test_override_existing_method
        k = Class.new(OpenStruct) do
            def m(a, b, c); end
        end
        s = k.new
        s.m = 10
        assert_equal 10, s.m
        assert_equal 10, s.send(:m)
        assert s.m?
    end

    def test_get
        s = OpenStruct.new
        assert_nil s.get(:x)
        s.x
        assert_nil s.get(:x)
        s.x = 20
        assert_equal 20, s.get(:x)
    end

    def test_to_hash
        s = OpenStruct.new
        s.a = 10
        s.b.a = 10

        assert_equal({ a: 10, b: { a: 10 } }, s.to_hash)
        assert_equal({ a: 10, b: s.b }, s.to_hash(false))
    end

    def test_pending_subfields_behaviour
        s = OpenStruct.new
        child = s.child
        refute_equal(child, s.child)
        child = s.child
        child.send(:attach)
        assert_equal(child, s.child)

        s = OpenStruct.new
        child = s.child
        assert_equal([s, "child"], child.send(:attach_as))
        s.child = 10
        # child should NOT attach itself to s
        assert_equal(10, s.child)
        assert(!child.send(:attach_as))

        child.test = 20
        refute_equal(child, s.child)
        assert_equal(10, s.child)
    end

    def test_field_attaches_when_read_from
        s = OpenStruct.new
        field = s.child
        assert !field.attached?
        field.test
        assert field.attached?
        assert_same(field, s.child)
    end

    def test_field_attaches_when_written_to
        s = OpenStruct.new
        field = s.child
        assert !field.attached?
        field.test = 10
        assert field.attached?
        assert_same(field, s.child)
    end

    def test_alias
        r = OpenStruct.new
        obj = Object.new
        r.child = obj
        r.alias(:child, :aliased_child)
        assert r.respond_to?(:aliased_child)
        assert r.aliased_child?
        assert_same obj, r.aliased_child

        obj = Object.new
        r.child = obj
        assert_same obj, r.aliased_child

        obj = Object.new
        r.aliased_child = obj
        assert_same obj, r.child
    end

    def test_delete_free_struct
        r = OpenStruct.new
        assert_raises(ArgumentError) { r.delete }
    end

    def test_delete_from_pending_child
        r = OpenStruct.new
        child = r.child
        child.delete
        child.value = 10
        assert(!r.child?)
    end

    def test_delete_specific_pending_child_from_parent
        r = OpenStruct.new
        child = r.child
        r.delete(:child)
        child.value = 10
        assert(!r.child?)
    end

    def test_delete_from_attached_child
        r = OpenStruct.new
        r.child.value = 10
        assert(r.child?)
        r.delete(:child)
        assert(!r.child?)
    end

    def test_delete_specific_attached_child_from_parent
        r = OpenStruct.new
        r.child.value = 10
        assert(r.child?)
        r.child.delete
        assert(!r.child?)
    end

    def test_delete_alias_from_parent
        r = OpenStruct.new
        r.child.value = 10
        r.alias(:child, :aliased_child)
        assert(r.aliased_child?)
        r.delete(:aliased_child)
        assert(!r.aliased_child?)
    end

    def test_delete_aliased_child_from_parent_deletes_the_alias
        r = OpenStruct.new
        r.child.value = 10
        r.alias(:child, :aliased_child)
        assert(r.aliased_child?)
        r.child.delete
        assert(!r.aliased_child?)
        assert(!r.child?)
    end

    def test_delete_from_attached_child_deletes_aliased_child
        r = OpenStruct.new
        r.child.value = 10
        r.alias(:child, :aliased_child)
        assert(r.aliased_child?)
        r.child.delete
        assert(!r.aliased_child?)
        assert(!r.child?)
    end

    def test_empty
        r = OpenStruct.new
        c = r.child
        assert(r.empty?)
        r.child = 10
        assert(!r.empty?)
        r.delete(:child)
        assert(r.empty?)
    end

    def test_filter
        s = OpenStruct.new
        s.filter(:test) do |v|
            Integer(v)
        end
        s.test = "10"
        assert_equal 10, s.test
    end

    def test_filter_can_call_stable
        s = OpenStruct.new
        s.filter(:test) do |v|
            result = OpenStruct.new
            result.value = v
            s.stable!
            result
        end
        s.test = 10
        assert s.stable?
        assert_kind_of OpenStruct, s.test
        assert_equal 10, s.test.value
    end

    def test_raising_filter_cancels_attachment
        s = OpenStruct.new
        s.filter(:test) do |v|
            Integer(v)
        end
        assert_raises(ArgumentError) { s.test = "a" }
        assert !s.test?
    end

    def test_raising_filter_cancels_update
        s = OpenStruct.new
        s.test = 10
        s.filter(:test) do |v|
            Integer(v)
        end
        assert_raises(ArgumentError) { s.test = "a" }
        assert s.test?
        assert_equal 10, s.test
    end

    def test_global_filter
        s = OpenStruct.new
        s.global_filter do |name, v|
            assert_equal "test", name
            Integer(v)
        end
        s.test = "10"
        assert_equal 10, s.test
    end

    def test_global_filter_can_call_stable
        s = OpenStruct.new
        s.global_filter do |name, v|
            assert_equal "test", name
            result = OpenStruct.new
            result.value = v
            s.stable!
            result
        end
        s.test = 10
        assert s.stable?
        assert_kind_of OpenStruct, s.test
        assert_equal 10, s.test.value
    end

    def test_raising_global_filter_cancels_attachment
        s = OpenStruct.new
        s.global_filter do |name, v|
            assert_equal "test", name
            Integer(v)
        end
        assert_raises(ArgumentError) { s.test = "a" }
        assert !s.test?
    end

    def test_raising_global_filter_cancels_update
        s = OpenStruct.new
        s.test = 10
        s.global_filter do |name, v|
            assert_equal "test", name
            Integer(v)
        end
        assert_raises(ArgumentError) { s.test = "a" }
        assert s.test?
        assert_equal 10, s.test
    end

    def test_on_change_attaches
        s = OpenStruct.new
        s.substruct.on_change { |_| }
        assert s.substruct.attached?
    end

    def test_on_change_recursive
        s = OpenStruct.new

        mock = flexmock
        s.on_change(:value, true) { |n, v| mock.updated(n, v) }
        mock.should_receive(:updated).with("value", 42).once
        s.value = 42

        mock = flexmock
        # Notification when substruct gets attached
        mock.should_receive(:updated).with("substruct", OpenStruct).once.ordered
        # Notification when the value gets written
        mock.should_receive(:updated).with("value", 42).once.ordered
        # Notification when the value gets written
        mock.should_receive(:updated).with("substruct", 42).once.ordered
        s.on_change(:substruct, true) { |n, v| mock.updated(n, v.value) }
        s.substruct.on_change(:value, true) { |n, v| mock.updated(n, v) }
        s.substruct.value = 42
    end

    def test_on_change_all_names
        s = OpenStruct.new
        mock = flexmock
        s.on_change(nil, false) { |n, v| mock.updated(n, v) }
        mock.should_receive(:updated).with("value", 42).once
        s.value = 42

        s = OpenStruct.new
        mock = flexmock
        mock.should_receive(:updated).with("substruct", any).once
        mock.should_receive(:updated).with("value", 42).once
        s.on_change(nil, false) { |n, v| mock.updated(n, v.value) }
        s.substruct.on_change(nil, false) { |n, v| mock.updated(n, v) }
        s.substruct.value = 42
    end

    def test_on_change_non_recursive
        s = OpenStruct.new

        mock = flexmock
        s.on_change(:value, false) { |n, v| mock.updated(n, v) }
        mock.should_receive(:updated).with("value", 42).once
        s.value = 42

        mock = flexmock
        # One notification when the substruct gets attached
        mock.should_receive(:updated).with("substruct", any).once
        # One notification when the value gets written
        mock.should_receive(:updated).with("value", 42).once
        s.on_change(:substruct, false) { |n, v| mock.updated(n, v.value) }
        s.substruct.on_change(:value, false) { |n, v| mock.updated(n, v) }
        s.substruct.value = 42
    end

    def test_predicate
        s = OpenStruct.new
        s.a = false
        s.b = 1
        s.unattached
        assert(!s.foobar?)
        assert(!s.unattached?)
        assert(!s.a?)
        assert(s.b?)
    end

    def test_marshalling
        s = OpenStruct.new
        s.value = 42
        s.substruct.value = 24
        s.invalid = proc {}

        s.on_change(:substruct) {}
        s.filter(:value) { |v| Numeric === v }

        str = nil
        str = Marshal.dump(s)
        s = Marshal.load(str)
        assert_equal(42, s.value)
        assert_equal(s, s.substruct.__parent_struct)
        assert_equal("substruct", s.substruct.__parent_name)
        assert_equal(24, s.substruct.value)
        assert(!s.respond_to?(:invalid))
    end

    def test_forbidden_names
        s = OpenStruct.new
        assert_raises(NoMethodError) { s.each_blah }
        s.blato
        assert_raises(NoMethodError) { s.enum_blah }
        assert_raises(NoMethodError) { s.to_blah }
    end

    def test_overrides_methods_that_are_not_protected
        s = OpenStruct.new
        def s.y(i); end
        assert_raises(ArgumentError) { s.y }
        s.y = 10
        assert_equal(10, s.y)
    end

    def test_existing_instance_methods_are_protected
        s = OpenStruct.new
        assert_raises(ArgumentError) { s.get = 10 }
    end

    def test_path
        s = OpenStruct.new
        assert_equal [], s.path
        s.pose.attach
        assert_equal ["pose"], s.pose.path
        s.pose.position.attach
        assert_equal %w[pose position], s.pose.position.path
    end

    def test_does_not_catch_equality_operators
        s = OpenStruct.new
        assert_raises(NoMethodError) { s <= 10 }
    end

    def test_parent
        s = OpenStruct.new
        assert !s.__parent

        s.pose.attach
        assert_same s.pose, s.pose.position.__parent
        assert_same s, s.pose.__parent
    end

    def test_root
        s = OpenStruct.new
        assert s.__root?

        assert !s.pose.position.__root?
        assert_same s, s.pose.position.__root
    end

    def test_attach_is_recursive
        s = OpenStruct.new
        field = s.a.deep.value
        assert !field.attached?
        field.value = 10
        assert field.attached?
        assert s.a.deep.attached?
        assert s.a.attached?
    end

    def test_create_with_model_initializes_structure
        m = OpenStructModel.new
        m.subfield.value = Object
        s = OpenStruct.new(m)
        assert s.subfield.attached?
    end

    def test_add_field_to_model_after_creation
        m = Roby::OpenStructModel.new
        s = Roby::OpenStruct.new(m)
        m.pose.position = Object
        assert_same Object, s.pose.model.position
    end

    def test_add_model_after_creation
        s = Roby::OpenStruct.new
        assert s.pose
        assert s.another_value

        m = s.new_model
        m.pose.position = OpenStructModel::Variable.new

        assert s.pose
        assert !s.pose.position
        assert !s.another_value

        s.pose.position = Object.new
    end

    def test_it_allows_to_test_for_the_presence_of_a_non_method
        s = Roby::OpenStruct.new
        assert !s.send("not:a:method?")
    end

    def test_it_raises_if_trying_to_access_a_non_method
        s = Roby::OpenStruct.new
        assert_raises(NoMethodError) do
            s.send("not:a:method")
        end
    end
end
