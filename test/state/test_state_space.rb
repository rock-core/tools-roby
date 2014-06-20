require 'roby/test/self'
require 'roby/state'

class TC_StateSpace < Minitest::Test
    class Position
    end

    def create_state_space(*fields)
        model = StateModel.new
        fields.each do |field_name|
            field_name = field_name.split('.')
            field_name, leaf_name = field_name[0..-2], field_name[-1]
            parent = field_name.inject(model) do |leaf, f|
                leaf.send(f)
            end
            parent.attach
            parent.__set(leaf_name, StateVariableModel.new(parent, leaf_name))
        end
        StateSpace.new(model)
    end

    def test_state_space_creates_structure
        m = StateModel.new
        pose = m.send('pose')
        pose.__set(:position, StateVariableModel.new(nil, nil))
        m.val = Class.new

        s = StateSpace.new(m)
        assert !s.no_value
        assert !s.val
        assert_kind_of(StateField, s.pose)
        assert_same(s.pose, s.pose)
        assert !s.pose.position
    end

    def test_state_space_only_allows_writing_on_variables
        m = StateModel.new
        m.pose.position = Position
        m.val = Position

        s = StateSpace.new(m)
        assert_raises(ArgumentError) { s.pose = 10 }
        assert_raises(ArgumentError) { s.does_not_exist = 10 }
        v = s.val = Position.new
        assert_same v, s.val
        v = s.pose.position = Position.new
        assert_same v, s.pose.position
    end

    def test_state_space_creation_does_not_modify_model
        m = StateModel.new
        m.pose.position = Position
        m.val = Position
        m.empty_field.attach

        val_field = m.val
        pose_field = m.pose
        position_field = m.pose.position
        empty_field = m.empty_field

        flexmock(m).should_receive(:__set).never
        flexmock(m).should_receive(:attach_child).and_raise(ArgumentError)

        s = StateSpace.new(m)
        assert_same val_field, m.val
        assert_same pose_field, m.pose
        assert_same position_field, m.pose.position
        assert_same empty_field, m.empty_field
    end

    def test_model_access_from_subfield
        s = create_state_space('pose.position')
        assert_same(s.pose.model, s.model.pose)
    end

    def test_field_model_is_accessible_from_the_field
        s = create_state_space('pose.position')
        s.model.pose.position = Position
        assert_equal Position, s.model.pose.position.type
        assert_same s.pose.model.position, s.model.pose.position

        s = create_state_space('pose.position')
        s.pose.model.position = Position
        assert_equal Position, s.model.pose.position.type
        assert_same s.pose.model.position, s.model.pose.position
    end

    def test_field_returns_nil_if_a_data_source_is_specified_and_no_value_exists
        s = StateSpace.new
        s.pose.data_sources.position = Object.new
        assert !s.pose.position
    end

    def test_field_cannot_be_assigned_if_a_data_source_is_specified
        s = create_state_space('pose.position')
        s.pose.data_sources.position = Object.new
        assert_raises(ArgumentError) { s.pose.position = Object.new }
    end

    def test_field_returns_nil_if_a_type_is_specified_and_no_value_exists
        s = create_state_space('pose.position')
        s.pose.model.position = Position
        assert !s.pose.position
    end

    def test_field_assignation_validates_type_if_model_gives_one
        s = create_state_space('pose.position')
        s.pose.model.position = Position
        s.pose.position = Position.new

        assert_raises(ArgumentError) { s.pose.position = Object.new }
    end

    def test_export
	s = create_state_space('pos.x', 'speed.x')
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

        s = create_state_space('pose.position')
        s.last_known.pose.__set(:position, source)
        assert_same s.pose.last_known.position, s.last_known.pose.position

        s = create_state_space('pose.position')
        s.pose.last_known.__set(:position, source)
        assert_same s.pose.last_known.position, s.last_known.pose.position
    end

    def test_last_known_is_read_only
        source = Object.new

        s = create_state_space('pose.position')
        assert_raises(ArgumentError) { s.last_known.pose.position = source }
    end

    def test_assigning_data_source_attaches_the_field
        s = StateSpace.new
        s.pose.data_sources.position = Object.new
        assert s.pose.data_sources.attached?
        assert_same s.data_sources, s.pose.data_sources.__parent_struct
        assert_equal "pose", s.pose.data_sources.__parent_name
    end

    def test_data_sources_is_accessible_from_the_field
        source = Object.new

        s = create_state_space('pose.position')
        s.data_sources.pose.position = source
        assert_same s.pose.data_sources.position, s.data_sources.pose.position

        s = create_state_space('pose.position')
        s.data_sources.pose.position = source
        assert_same s.pose.data_sources.position, s.data_sources.pose.position

        s = create_state_space('pose.position')
        s.pose.data_sources.position = source
        assert_same s.pose.data_sources.position, s.data_sources.pose.position
    end

    def test_state_model_read
        source = flexmock
        source.should_receive(:read).once.
            and_return(obj = Object.new)

        s = create_state_space('pose.position')

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

        s = create_state_space('pose.position')
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
        s = StateModel.new
        klass = Class.new
        s.pose.position = klass
        assert_equal %w{pose position}, s.pose.position.path
    end

    def test_state_model_resolve_data_sources
        source_model = flexmock
        source_model.should_receive(:to_state_variable_model).
            and_return do |field, name|
                var = StateVariableModel.new(field, name)
                var.data_source = source_model
                var
            end

        model = StateModel.new
        model.pose.position = source_model

        state = StateSpace.new(model)

        obj = Object.new
        source = flexmock
        source_model.should_receive(:resolve).with(obj).once.
            and_return(source)
        model.resolve_data_sources(obj, state)
        assert_equal source, state.data_sources.pose.position
    end

    def test_global_state_can_be_given_a_model_after_the_fact
        # State should be open at this point
        assert !State.model
        assert State.position
        State.new_model
        # Now create a model
        State.model.position = Object
        # And it should now follow it
        assert_equal Object, State.model.position.type
        assert !State.value
    end
end


