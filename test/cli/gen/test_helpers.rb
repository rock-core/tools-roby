# frozen_string_literal: true

require "roby/test/self"
require "roby/cli/gen/helpers"

module Roby
    module CLI
        module Gen
            describe Helpers do
                describe "#resolve_name" do
                    subject = nil
                    before do
                        Roby.app.module_name = "TestApp"
                        subject = Object.new
                        subject.extend Helpers
                    end
                    describe "when given a path" do
                        it "resolves a path relative to the app's root" do
                            file_name, class_name = subject.resolve_name("actions", "models/actions/test.rb", nil,
                                                                         %w[models actions], ["Actions"])
                            assert_equal ["test"], file_name
                            assert_equal %w[TestApp Actions Test], class_name
                        end
                        it "handles sub-paths from the expected root path" do
                            file_name, class_name = subject.resolve_name("actions", "models/actions/somewhere/within/test.rb", nil,
                                                                         %w[models actions], ["Actions"])
                            assert_equal %w[somewhere within test], file_name
                            assert_equal %w[TestApp Actions Somewhere Within Test], class_name
                        end
                        it "resolves a path also given the robot name" do
                            file_name, class_name = subject.resolve_name("actions", "models/actions/test_robot/test.rb", "test_robot",
                                                                         %w[models actions], ["Actions"])
                            assert_equal %w[test_robot test], file_name
                            assert_equal %w[TestApp Actions TestRobot Test], class_name
                        end
                        it "does not require the ending .rb extension" do
                            file_name, class_name = subject.resolve_name("actions", "models/actions/test_robot/test", "test_robot",
                                                                         %w[models actions], ["Actions"])
                            assert_equal %w[test_robot test], file_name
                            assert_equal %w[TestApp Actions TestRobot Test], class_name
                        end
                        it "resolves a path relative to the file root" do
                            file_name, class_name = subject.resolve_name("actions", "test.rb", nil,
                                                                         %w[models actions], ["Actions"])
                            assert_equal ["test"], file_name
                            assert_equal %w[TestApp Actions Test], class_name
                        end
                        it "aborts if the user provides an unexpected root path" do
                            e = assert_raises(CLIInvalidArguments) do
                                subject.resolve_name("actions", "models/tasks/test.rb", nil,
                                                     %w[models actions], ["Actions"])
                            end
                            assert_equal "attempted to create a actions model outside of models/actions",
                                         e.message
                        end
                        it "aborts if the user refuses to force an unexpected robot subfolder" do
                            e = assert_raises(CLIInvalidArguments) do
                                subject.resolve_name("actions", "models/actions/test.rb", "test_robot",
                                                     %w[models actions], ["Actions"])
                            end
                            assert_equal "attempted to create a model for robot test_robot outside a test_robot/ subfolder",
                                         e.message
                        end
                    end

                    describe "when given a constant name" do
                        it "processes an absolute module name as-is" do
                            file_name, class_name = subject.resolve_name("actions", "TestApp::Actions::Test", nil,
                                                                         %w[models actions], ["Actions"])
                            assert_equal ["test"], file_name
                            assert_equal %w[TestApp Actions Test], class_name
                        end
                        it "handles sub-namespaces of the absolute namespace" do
                            file_name, class_name = subject.resolve_name("actions", "TestApp::Actions::Somewhere::Within::Test", nil,
                                                                         %w[models actions], ["Actions"])
                            assert_equal %w[somewhere within test], file_name
                            assert_equal %w[TestApp Actions Somewhere Within Test], class_name
                        end
                        it "prepends the app module if it's not there already" do
                            file_name, class_name = subject.resolve_name("actions", "Actions::Test", nil,
                                                                         %w[models actions], ["Actions"])
                            assert_equal ["test"], file_name
                            assert_equal %w[TestApp Actions Test], class_name
                        end
                        it "handles sub-namespaces of the root namespace" do
                            file_name, class_name = subject.resolve_name("actions", "Actions::Somewhere::Within::Test", nil,
                                                                         %w[models actions], ["Actions"])
                            assert_equal %w[somewhere within test], file_name
                            assert_equal %w[TestApp Actions Somewhere Within Test], class_name
                        end
                        it "prepends the app and namespace root modules if they are not there already" do
                            file_name, class_name = subject.resolve_name("actions", "Test", nil,
                                                                         %w[models actions], ["Actions"])
                            assert_equal ["test"], file_name
                            assert_equal %w[TestApp Actions Test], class_name
                        end
                        it "handles sub-namespaces of a relative namespace" do
                            file_name, class_name = subject.resolve_name("actions", "Somewhere::Within::Test", nil,
                                                                         %w[models actions], ["Actions"])
                            assert_equal %w[somewhere within test], file_name
                            assert_equal %w[TestApp Actions Somewhere Within Test], class_name
                        end
                        it "raises if the model is not within its expected namespace" do
                            e = assert_raises(CLIInvalidArguments) do
                                subject.resolve_name("actions", "TestApp::Tasks::Test", nil,
                                                     %w[models actions], ["Actions"])
                            end
                            assert_equal "attempted to create a actions model outside of its expected namespace TestApp::Actions",
                                         e.message
                        end
                        it "raises if the model is not within its expected robot namespace" do
                            e = assert_raises(CLIInvalidArguments) do
                                subject.resolve_name("actions", "TestApp::Actions::Test", "test_robot",
                                                     %w[models actions], ["Actions"])
                            end
                            assert_equal "attempted to create a model for robot test_robot outside the expected namespace TestRobot (e.g. TestApp::Actions::TestRobot::Test)",
                                         e.message
                        end
                    end
                end
            end
        end
    end
end
