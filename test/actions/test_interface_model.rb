$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/actions'
require 'flexmock/test_unit'

class TC_Actions_InterfaceModel < Test::Unit::TestCase
    include Roby::Planning
    include Roby::SelfTest
    include Roby::SelfTest::Assertions

    def test_it_allows_to_create_description_objects
        doc = 'this is an action'
        m = Class.new(Actions::Interface)
        flexmock(Actions::ActionModel).should_receive(:new).once.
            with(m, doc).and_return(stub = Object.new)

        assert_same stub, m.describe(doc)
    end

    def test_it_exports_methods_with_description
        m = Class.new(Actions::Interface)
        description = m.describe('an action')
        m.class_eval do
            def an_action
            end
        end
        assert_equal 'an_action', description.name
        assert_same description, m.find_action_by_name('an_action')
        assert_same description, m.find_action_by_name(:an_action)
    end

    def test_it_returns_nil_for_unknown_actions
        m = Class.new(Actions::Interface) do
            describe('an action')
            def an_action; end
        end
        assert !m.find_action_by_name('bla')
    end

    def test_it_does_not_export_methods_without_description
        m = Class.new(Actions::Interface) do
            def an_action; end
        end
        assert !m.find_action_by_name('an_action')
    end

    def test_it_allows_to_find_methods_by_type
        task_m = Class.new(Roby::Task)
        subtask_m = Class.new(task_m)
        m0, m1 = nil
        actions = Class.new(Actions::Interface) do
            m0 = describe('an action').returns(task_m)
            def an_action; end
            m1 = describe('another action').returns(subtask_m)
            def another_action; end
        end
        assert_equal [m0, m1].to_set, actions.find_all_actions_by_type(task_m).to_set
        assert_equal [m1], actions.find_all_actions_by_type(subtask_m)
    end

    def test_it_allows_to_get_an_action_object_dynamically
        m = nil
        actions = Class.new(Actions::Interface) do
            m = describe('an action').
                required_arg('test')
            def an_action(arguments); end
        end
        act = actions.an_action('test' => 10)
        assert_same m, act.model
        assert_equal Hash['test' => 10], act.arguments
    end

    def test_action_libraries_are_not_registered_as_submodels
        library = Module.new do
            action_library
        end
        assert !Actions::Interface.each_submodel.to_a.include?(library)
    end

    def test_it_raises_if_an_action_model_specifies_arguments_but_the_method_does_not_accept_one
        assert_raises(Actions::InterfaceModel::ArgumentCountMismatch) do
            Class.new(Actions::Interface) do
                m = describe('an action').
                    required_arg('test')
                def an_action; end
            end
        end
    end

    def test_it_raises_if_an_action_model_specifies_no_arguments_but_the_method_expects_one
        assert_raises(Actions::InterfaceModel::ArgumentCountMismatch) do
            Class.new(Actions::Interface) do
                m = describe('an action')
                def an_action(argument); end
            end
        end
    end

    def test_it_passes_the_argument_hash_if_the_method_expects_one
        task_m = Class.new(Roby::Task) { argument :id }
        actions = Class.new(Actions::Interface) do
            m = describe('an action').
                required_arg('test')
            define_method(:an_action) { |args| task_m.new(:id => args[:test]) }
        end
        assert_equal 10, actions.an_action(:test => 10).instanciate(plan).id
    end

    def test_inherited_actions_are_rebound_to_the_interface_model
        parent_m = Class.new(Actions::Interface) do
            describe('an action')
            def an_action; end
        end
        child_m = Class.new(parent_m)
        assert_same child_m, child_m.find_action_by_name('an_action').action_interface_model
        # Verify it did not modify the original
        assert_same parent_m, parent_m.find_action_by_name('an_action').action_interface_model
    end

    def test_it_defines_a_simple_task_model_for_return_type_if_none_is_given
        parent_m = Class.new(Actions::Interface) do
            describe('an action')
            def an_action; end
        end
        assert_equal parent_m::AnAction, parent_m.find_action_by_name('an_action').returned_type
    end
end