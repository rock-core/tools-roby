$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock/test_unit'
require 'roby/state'

class TC_StateModel < Test::Unit::TestCase
    include Roby::SelfTest

    class Position
    end

    def test_assign_on_state_field_model_calls_to_state_variable_model
        klass = flexmock
        klass.should_receive(:to_state_variable_model).once.
            and_return(obj = Object.new)

        m = StateModel.new
        m.position = klass
        assert_same obj, m.position
    end

    def test_class_to_state_variable_model
        klass = Class.new
        model = klass.to_state_variable_model('a', 'b')
        assert_equal 'a', model.field
        assert_equal 'b', model.name
        assert !model.data_source
        assert_same klass, model.type
    end

    def test_state_variable_path
        m = StateModel.new
        m.pose.position = Position
        assert_equal [], m.path
        assert_equal ['pose'], m.pose.path
        assert_equal ['pose', 'position'], m.pose.position.path
    end

    def test_child_model_creation
        parent_model = StateModel.new
        child_model = StateModel.new(parent_model)
        assert_same parent_model, child_model.superclass
    end

    def test_child_model_accesses_parent_members
        parent_model = StateModel.new
        child_model = StateModel.new(parent_model)

        parent_model.pose = Position
        assert child_model.pose?
        assert_same parent_model.pose, child_model.pose
    end

    def test_child_model_does_not_change_parent
        parent_model = StateModel.new
        child_model = StateModel.new(parent_model)
        child_model.pose = Position
        assert !parent_model.pose?
    end

    def test_child_model_access_creates_new_subfields_attached_to_the_parent_subfields
        parent_model = StateModel.new
        child_model = StateModel.new(parent_model)

        parent_model.pose.position = Position
        child_field = child_model.pose
        assert_not_same parent_model.pose, child_field
        assert_same parent_model.pose, child_field.superclass
    end

    def test_assign_variable_model_validation
        m = StateModel.new
        assert_raises(ArgumentError) { m.position = Object.new }
    end
end

