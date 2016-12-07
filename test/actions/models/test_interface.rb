require 'roby/test/self'

module Roby
    module Actions
        module Models
            describe Interface do
                attr_reader :interface_m
                before do
                    @interface_m = Actions::Interface.new_submodel
                end

                it "does not register action libraries as submodels of Actions::Interface" do
                    library = Module.new { action_library }
                    refute Actions::Interface.each_submodel.to_a.include?(library)
                end


                describe "the action definition workflow" do
                    it "creates a description object with #describe" do
                        doc = 'this is an action'
                        flexmock(Actions::Models::Action).should_receive(:new).once.
                            with(interface_m, doc).and_return(stub = Object.new)

                        assert_same stub, interface_m.describe(doc)
                    end

                    it "registers the description object when a method is created" do
                        description = interface_m.describe('an action')
                        interface_m.send(:define_method, :an_action) {}
                        assert_equal 'an_action', description.name
                        assert_same description, interface_m.find_action_by_name('an_action')
                    end

                    it "does not export a method that does not have a description" do
                        interface_m.send(:define_method, :an_action) {}
                        assert_nil interface_m.find_action_by_name('an_action')
                    end

                    it "does not use the same description for multiple methods" do
                        description = interface_m.describe('an action')
                        interface_m.send(:define_method, :an_action) {}
                        interface_m.send(:define_method, :another_action) {}
                        assert_nil interface_m.find_action_by_name('another_action')
                    end

                    it "automatically defines a return type for the action if none is provided" do
                        interface_m.describe 'an action'
                        interface_m.send(:define_method, 'an_action') {}
                        assert_equal interface_m::AnAction,
                            interface_m.find_action_by_name('an_action').returned_type
                    end


                    it "reuses a parent model's action return type when overloading" do
                        task_m = Roby::Task.new_submodel
                        interface_m.describe('an action').returns(task_m)
                        interface_m.send(:define_method, :test) { }

                        submodel_m = interface_m.new_submodel
                        submodel_m.describe('an overload')
                        submodel_m.send(:define_method, :test) { }

                        assert_same task_m, submodel_m.find_action_by_name(:test).returned_type
                    end

                    describe "argument handling" do
                        attr_reader :action_m
                        before do
                            @action_m = interface_m.describe('an action')
                        end
                        def define_action(&block)
                            interface_m.send(:define_method, :an_action, &block)
                        end
                        def expect_arguments(args)
                            flexmock(interface_m).new_instances.
                                should_receive(:an_action).with(args).pass_thru.once
                        end

                        it "sets up default arguments" do
                            action_m.optional_arg('test', nil, 10)
                            define_action { |args = Hash.new| self.class::AnAction.new }
                            expect_arguments test: 10
                            interface_m.an_action.instanciate(plan)
                        end

                        it "raises if the action has only optional arguments but the method expects no arguments at all" do
                            action_m.optional_arg('test', nil, 10)
                            assert_raises(Roby::Actions::Models::Interface::ArgumentCountMismatch) do
                                define_action { }
                            end
                        end

                        it "raises if the action has only optional arguments but the method expects more than one argument" do
                            action_m.optional_arg('test', nil, 10)
                            assert_raises(Roby::Actions::Models::Interface::ArgumentCountMismatch) do
                                define_action { |a, b| }
                            end
                        end

                        it "raises if the action has required arguments but the method expects no arguments at all" do
                            action_m.required_arg('test')
                            assert_raises(Roby::Actions::Models::Interface::ArgumentCountMismatch) do
                                define_action { }
                            end
                        end

                        it "raises if the action has required arguments but the method expects more than one argument" do
                            action_m.required_arg('test')
                            assert_raises(Roby::Actions::Models::Interface::ArgumentCountMismatch) do
                                define_action { |a, b| }
                            end
                        end

                        it "raises if the action has no arguments but the method expects some" do
                            assert_raises(Roby::Actions::Models::Interface::ArgumentCountMismatch) do
                                define_action { |a| }
                            end
                        end

                        it "allows to override default arguments" do
                            action_m.optional_arg('test', nil, 10)
                            define_action { |args = Hash.new| self.class::AnAction.new }
                            expect_arguments test: 20
                            interface_m.an_action.instanciate(plan, test: 20)
                        end

                        it "raises ArgumentError if a required argument is not given" do
                            action_m.required_arg('test', nil)
                            define_action { |args| }
                            assert_raises(ArgumentError) do
                                interface_m.an_action.instanciate(plan)
                            end
                        end

                        it "raises ArgumentError if arguments are given but the action expects none" do
                            define_action {  }
                            assert_raises(ArgumentError) do
                                interface_m.an_action.instanciate(plan, test: 10)
                            end
                        end
                    end
                end

                describe "#find_action_by_name" do
                    attr_reader :description
                    before do
                        @description = interface_m.describe 'an_action'
                        interface_m.send(:define_method, :an_action) {}
                    end
                    it "works with symbols" do
                        assert_same description, interface_m.find_action_by_name(:an_action)
                    end
                    it "works with strings" do
                        assert_same description, interface_m.find_action_by_name('an_action')
                    end
                    it "returns nil for unknown actions" do
                        assert_nil interface_m.find_action_by_name('does_not_exist')
                    end
                end

                describe "#find_all_actions_by_type" do
                    it "finds actions whose return type is the expected type" do
                        task_m = Roby::Task.new_submodel
                        action_m = interface_m.describe('an action').returns(task_m)
                        interface_m.send(:define_method, 'action') {}
                        assert_equal [action_m], interface_m.find_all_actions_by_type(task_m)
                    end
                    it "finds actions whose return type is a subclass of the expected type" do
                        task_m = Roby::Task.new_submodel
                        subtask_m = task_m.new_submodel
                        action_m = interface_m.describe('an action').returns(task_m)
                        interface_m.send(:define_method, 'action') {}
                        subclass_action_m = interface_m.describe('subclass action').returns(subtask_m)
                        interface_m.send(:define_method, 'subclass_action') {}
                        assert_equal Set[action_m, subclass_action_m],
                            interface_m.find_all_actions_by_type(task_m).to_set
                    end
                end

                describe "#method_missing" do
                    it "returns an action object with the given arguments" do
                        action_m = interface_m.describe('an action').required_arg('test')
                        interface_m.send(:define_method, 'an_action') { |args| }
                        act = interface_m.an_action(test: 10)
                        assert_same action_m, act.model
                        assert_equal Hash[test: 10], act.arguments
                    end
                end

                describe "action promotion" do
                    def define_action(interface_m, action_name)
                        interface_m.describe action_name
                        interface_m.send(:define_method, action_name) {}
                    end

                    it "rebinds inherited actions to self" do
                        define_action(interface_m, 'action')
                        child_m = interface_m.new_submodel
                        assert_same child_m, child_m.
                            find_action_by_name('action').action_interface_model
                    end
                    it "does not modify the original" do
                        define_action(interface_m, 'action')
                        child_m = interface_m.new_submodel
                        assert_same interface_m, interface_m.
                            find_action_by_name('action').action_interface_model
                    end
                end

                describe "support for coordination models" do
                    it "creates an action state machine at the model level" do
                        interface_m.describe 'a state machine'
                        _, machine_m = interface_m.action_state_machine('test') do
                            start state(Roby::Task)
                        end
                        assert_same machine_m, interface_m.find_action_by_name('test').
                            to_coordination_model

                        action = interface_m.new(plan)
                        root_task = action.test
                        assert_kind_of machine_m, root_task.each_coordination_object.first
                    end

                    it "creates an action state machine at the action level" do
                        interface_m.describe 'a state machine'
                        coordination_object = nil
                        interface_m.send(:define_method, :test) do
                            coordination_object = action_state_machine(task = Roby::Task.new) do
                                start state(Roby::Task)
                            end
                            task
                        end
                        root_task = interface_m.new(plan).test
                        assert_equal coordination_object,
                            root_task.each_coordination_object.first
                    end

                    it "creates an action script at the model level" do
                        interface_m.describe 'a state machine'
                        _, script_m = interface_m.action_script('test') do
                        end
                        assert_equal script_m, interface_m.find_action_by_name('test').
                            to_coordination_model
                        root_task = interface_m.new(plan).test
                        assert_kind_of script_m, root_task.each_coordination_object.first
                    end

                    it "creates an action script at the instance level" do
                        interface_m.describe 'a state machine'
                        coordination_object = nil
                        interface_m.send(:define_method, :test) do
                            coordination_object = action_script(task = Roby::Task.new) { }
                            task
                        end
                        root_task = interface_m.new(plan).test
                        assert_equal coordination_object,
                            root_task.each_coordination_object.first
                    end
                end
            end
        end
    end
end

