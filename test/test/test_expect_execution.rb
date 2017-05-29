require 'roby/test/self'

module Roby
    module Test
        describe ExpectExecution do
            describe "#expect_execution" do
                it "can be created in parallel" do
                    first, second = nil
                    expectations0 = expect_execution { first = true }
                    expectations1 = expect_execution { second = true }
                    expectations0.to { achieve { first } }
                    expectations1.to { achieve { second } }
                end
                it "cannot be executed recursively within the event processing block" do
                    assert_raises(ExpectExecution::InvalidContext) do
                        expect_execution do
                            expect_execution { }
                        end.to { }
                    end
                end
                it "cannot be executed recursively within the expectation block" do
                    assert_raises(ExpectExecution::InvalidContext) do
                        expect_execution.to do
                            expect_execution.to { }
                        end
                    end
                end
            end

            describe "#add_expectations" do
                it "adds a new expectation from within the event processing block" do
                    called = false
                    expect_execution do
                        add_expectations do
                            achieve { called = true }
                        end
                    end.to { }
                    assert called
                end
                it "ignores the return values of expectations added this way" do
                    expected_ret = flexmock
                    ret = expect_execution do
                        add_expectations do
                            achieve { true }
                        end
                    end.to { achieve { expected_ret } }
                    assert_equal expected_ret, ret
                end
            end
        end
    end
end
