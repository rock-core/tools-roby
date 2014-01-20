$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/self'
require 'roby/actions'
require 'flexmock/test_unit'

class TC_Actions_InterfaceModel < Test::Unit::TestCase
    include Roby::SelfTest
    include Roby::SelfTest::Assertions

    def test_it_allows_to_create_description_objects
        doc = 'this is an action'
        m = Actions::Interface.new_submodel
        flexmock(Actions::Models::Action).should_receive(:new).once.
            with(m, doc).and_return(stub = Object.new)

        assert_same stub, m.describe(doc)
    end

    def test_it_exports_methods_with_description
        m = Actions::Interface.new_submodel
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
        m = Actions::Interface.new_submodel do
            describe('an action')
            def an_action; end
        end
        assert !m.find_action_by_name('bla')
    end

    def test_it_does_not_export_methods_without_description
        m = Actions::Interface.new_submodel do
            def an_action; end
        end
        assert !m.find_action_by_name('an_action')
    end

    def test_it_adds_default_arguments_to_the_action
        m = Actions::Interface.new_submodel
        description = m.describe('an action').
            optional_arg('test', nil, 10)
        m.class_eval { def an_action(args = Hash.new); self.class::AnAction.new end }
        flexmock(m).new_instances.should_receive(:an_action).with(:test => 10).pass_thru.once
        m.an_action.instanciate(plan)
    end

    def test_it_allows_to_override_default_arguments
        m = Actions::Interface.new_submodel
        description = m.describe('an action').
            optional_arg('test', nil, 10)
        m.class_eval { def an_action(args = Hash.new); self.class::AnAction.new end }
        flexmock(m).new_instances.should_receive(:an_action).with(:test => 20).pass_thru.once
        m.an_action.instanciate(plan, :test => 20)
    end

    def test_it_raises_ArgumentError_if_a_required_argument_is_not_given
        m = Actions::Interface.new_submodel
        description = m.describe('an action').
            required_arg('test', nil)
        m.class_eval { def an_action(args = Hash.new); end }
        assert_raises(ArgumentError) do
            m.an_action.instanciate(plan)
        end
    end

    def test_it_raises_ArgumentError_if_arguments_are_given_but_the_action_does_not_expect_any
        m = Actions::Interface.new_submodel
        description = m.describe('an action')
        m.class_eval { def an_action(args = Hash.new); end }
        assert_raises(ArgumentError) do
            m.an_action.instanciate(plan, :test => 10)
        end
    end

    def test_it_allows_to_find_methods_by_type
        task_m = Roby::Task.new_submodel
        subtask_m = task_m.new_submodel
        m0, m1 = nil
        actions = Actions::Interface.new_submodel do
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
        actions = Actions::Interface.new_submodel do
            m = describe('an action').
                required_arg('test')
            def an_action(arguments); AnAction.new end
        end
        act = actions.an_action('test' => 10)
        assert_same m, act.model
        assert_equal Hash[:test => 10], act.arguments
    end

    def test_action_libraries_are_not_registered_as_submodels
        library = Module.new do
            action_library
        end
        assert !Actions::Interface.each_submodel.to_a.include?(library)
    end

    def test_it_raises_if_an_action_model_specifies_arguments_but_the_method_does_not_accept_one
        assert_raises(Actions::Models::Interface::ArgumentCountMismatch) do
            Actions::Interface.new_submodel do
                m = describe('an action').
                    required_arg('test')
                def an_action; AnAction.new end
            end
        end
    end

    def test_it_raises_if_an_action_model_specifies_no_arguments_but_the_method_expects_one
        assert_raises(Actions::Models::Interface::ArgumentCountMismatch) do
            Actions::Interface.new_submodel do
                m = describe('an action')
                def an_action(argument); end
            end
        end
    end

    def test_it_passes_the_argument_hash_if_the_method_expects_one
        task_m = Roby::Task.new_submodel { argument :id }
        actions = Actions::Interface.new_submodel do
            m = describe('an action').
                required_arg('test')
            define_method(:an_action) { |args| task_m.new(:id => args[:test]) }
        end
        assert_equal 10, actions.an_action(:test => 10).instanciate(plan).id
    end

    def test_inherited_actions_are_rebound_to_the_interface_model
        parent_m = Actions::Interface.new_submodel do
            describe('an action')
            def an_action; end
        end
        child_m = parent_m.new_submodel
        assert_same child_m, child_m.find_action_by_name('an_action').action_interface_model
        # Verify it did not modify the original
        assert_same parent_m, parent_m.find_action_by_name('an_action').action_interface_model
    end

    def test_it_defines_a_simple_task_model_for_return_type_if_none_is_given
        parent_m = Actions::Interface.new_submodel do
            describe('an action')
            def an_action; end
        end
        assert_equal parent_m::AnAction, parent_m.find_action_by_name('an_action').returned_type
    end

    def test_it_allows_to_create_an_action_state_machine_at_model_level
        action_m = Actions::Interface.new_submodel
        action_m.describe 'a state machine'
        action_m.action_state_machine('test') do
            start state(Roby::Task)
        end
        action = action_m.new(plan)
        action.test
    end

    def test_it_allows_to_create_an_action_state_machine_at_action_level
        action_m = Actions::Interface.new_submodel
        action_m.describe 'a state machine'
        action_m.send(:define_method, :test) do
            task = Roby::Task.new
            action_state_machine(task) do
                start state(Roby::Task)
            end
            task
        end
        action = action_m.new(plan)
        action.test
    end

    def test_it_allows_to_create_an_action_script_at_model_level
        action_m = Actions::Interface.new_submodel
        action_m.describe 'a state machine'
        action_m.action_script('test') do
        end
        action = action_m.new(plan)
        action.test
    end

    def test_it_allows_to_create_an_action_script_at_action_level
        action_m = Actions::Interface.new_submodel
        action_m.describe 'a state machine'
        action_m.send(:define_method, :test) do
            task = Roby::Task.new
            action_script(task) do
            end
            task
        end
        action = action_m.new(plan)
        action.test
    end

end
