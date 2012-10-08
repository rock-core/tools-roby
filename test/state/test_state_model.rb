$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock/test_unit'
require 'roby/state'

class TC_StateModel < Test::Unit::TestCase
    include Roby::SelfTest

    class Position
    end

    def test_model_access_from_subfield
        s = StateModel.new
        assert_same(s.pose.model, s.model.pose)
    end

    def test_assign_leaf_model_calls_to_state_leaf_model
        klass = flexmock
        klass.should_receive(:to_state_leaf_model).twice.
            and_return(obj = Object.new)

        s = StateModel.new
        s.model.position = klass
        assert_same obj, s.model.position

        s = StateModel.new
        s.pose.model.position = klass
        assert_same obj, s.pose.model.position
    end

    def test_class_to_state_leaf_model
        klass = Class.new
        model = klass.to_state_leaf_model('a', 'b')
        assert_equal 'a', model.field
        assert_equal 'b', model.name
        assert !model.data_source
        assert_same klass, model.type
    end

    def test_assign_leaf_model_validation
        s = StateModel.new
        assert_raises(ArgumentError) { s.model.position = Object.new }
    end

    def test_child_state_model_creation
        parent_model = StateFieldModel.new
        child_model = StateFieldModel.new(parent_model)
        assert_same parent_model, child_model.superclass
    end

    def test_child_state_model_accesses_parent_members
        parent_model = StateFieldModel.new
        child_model = StateFieldModel.new(parent_model)

        parent_model.pose = Position
        assert child_model.pose?
        assert_same parent_model.pose, child_model.pose
    end

    def test_child_state_model_does_not_change_parent
        parent_model = StateFieldModel.new
        child_model = StateFieldModel.new(parent_model)
        child_model.pose = Position
        assert !parent_model.pose?
    end

    def test_child_state_model_access_creates_new_subfields_attached_to_the_parent_subfields
        parent_model = StateFieldModel.new
        child_model = StateFieldModel.new(parent_model)

        parent_model.pose.position = Position
        child_field = child_model.pose
        assert_not_same parent_model.pose, child_field
        assert_same parent_model.pose, child_field.superclass
    end

    def test_field_model_is_accessible_from_the_field
        s = StateModel.new
        s.model.pose.position = Position
        assert_same s.pose.model.position, s.model.pose.position

        s = StateModel.new
        s.pose.model.position = Position
        assert_same s.pose.model.position, s.model.pose.position
    end

    def test_field_returns_nil_if_a_data_source_is_specified_and_no_value_exists
        s = StateModel.new
        s.pose.data_sources.position = Object.new
        assert !s.pose.position
    end

    def test_field_cannot_be_assigned_if_a_data_source_is_specified
        s = StateModel.new
        s.pose.data_sources.position = Object.new
        assert_raises(ArgumentError) { s.pose.position = Object.new }
    end

    def test_field_returns_nil_if_a_type_is_specified_and_no_value_exists
        s = StateModel.new
        s.pose.model.position = Position
        assert !s.pose.position
    end

    def test_field_assignation_validates_type_if_model_gives_one
        s = StateModel.new
        s.pose.model.position = Position
        s.pose.position = Position.new

        assert_raises(ArgumentError) { s.pose.position = Object.new }
    end

    def test_export
	s = StateModel.new
	s.pos.x   = 42
	s.speed.x = 0

	obj = Marshal.load(Marshal.dump(s))
	assert(obj.respond_to?(:pos))
	assert(obj.respond_to?(:speed))
	assert_equal(42, obj.pos.x)
	assert_equal(0, obj.speed.x)

	s.export :pos
	obj = Marshal.load(Marshal.dump(s))
	assert(obj.respond_to?(:pos))
	assert(!obj.respond_to?(:speed))
	assert_equal(42, obj.pos.x)

	s.export :speed
	obj = Marshal.load(Marshal.dump(s))
	assert(obj.respond_to?(:pos))
	assert(obj.respond_to?(:speed))
	assert_equal(42, obj.pos.x)
	assert_equal(0, obj.speed.x)

        s.export_none
	obj = Marshal.load(Marshal.dump(s))
	assert(!obj.respond_to?(:pos))
	assert(!obj.respond_to?(:speed))

        s.export_all
	obj = Marshal.load(Marshal.dump(s))
	assert(obj.respond_to?(:pos))
	assert(obj.respond_to?(:speed))
	assert_equal(42, obj.pos.x)
	assert_equal(0, obj.speed.x)
    end

    def test_last_known_is_accessible_from_the_field
        source = Object.new

        s = StateModel.new
        s.last_known.pose.__set(:position, source)
        assert_same s.pose.last_known.position, s.last_known.pose.position

        s = StateModel.new
        s.pose.last_known.__set(:position, source)
        assert_same s.pose.last_known.position, s.last_known.pose.position
    end

    def test_last_known_is_read_only
        source = Object.new

        s = StateModel.new
        assert_raises(ArgumentError) { s.last_known.pose.position = source }
    end

    def test_data_sources_is_accessible_from_the_field
        source = Object.new

        s = StateModel.new
        s.data_sources.pose.position = source
        assert_same s.pose.data_sources.position, s.data_sources.pose.position

        s = StateModel.new
        s.data_sources.pose.position = source
        assert_same s.pose.data_sources.position, s.data_sources.pose.position
    end

    def test_state_model_read
        source = flexmock
        source.should_receive(:read).once.
            and_return(obj = Object.new)

        s = StateModel.new

        s.data_sources.pose.position = source
        assert !s.pose.position?
        s.pose.read
        assert_same obj, s.pose.position
        assert_same obj, s.last_known.pose.position

        source.should_receive(:read).once.and_return(nil)
        s.pose.read
        assert_same nil, s.pose.position
        assert_same obj, s.last_known.pose.position
    end

    def test_state_model_read_should_validate_type
        source = flexmock
        source.should_receive(:read).once.
            and_return(obj = Object.new)
        field_type = Class.new

        s = StateModel.new
        s.model.pose.position = field_type
        s.data_sources.pose.position = source
        assert_raises(ArgumentError) { s.pose.read }
        assert !s.pose.position?
        assert !s.last_known.pose.position?
        source.should_receive(:read).once.
            and_return(field_type.new)
        s.pose.read

    end

    def test_state_leaf_model_path
        s = StateFieldModel.new
        klass = Class.new
        s.pose.position = klass
        assert_equal %w{pose position}, s.pose.position.path
    end

    def test_state_field_model_initialization_with_object
        object = flexmock
        object.should_receive(:respond_to?).with(:superclass).and_return(false).once
        
        s = StateFieldModel.new(object)
        assert_same object, s.__object
        assert_same object, s.position.__object
    end

    def test_state_field_model_automatically_gets_supermodel_from_object
        parent = flexmock(:state => (parent_state = Object.new))
        child = flexmock(:superclass => parent)
        s = StateFieldModel.new(child)
        assert_same child, s.__object
        assert_same parent_state, s.superclass
    end

    def test_state_field_model_rebind
        s = StateFieldModel.new
        s.__rebind(obj = Object.new)
        assert_same obj, s.__object
        s.__rebind(obj = Object.new)
        assert_same obj, s.__object

        s.position.attach
        assert_raises(ArgumentError) { s.position.__rebind(Object.new) }
        assert_same obj, s.position.__object
    end
end

