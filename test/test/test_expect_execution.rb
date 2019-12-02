# frozen_string_literal: true

require 'roby/test/self'

module Roby
    module Test
        describe ExpectExecution do
            describe '#expect_execution' do
                it 'can be created in parallel' do
                    first, second = nil
                    expectations0 = expect_execution { first = true }
                    expectations1 = expect_execution { second = true }
                    expectations0.to { achieve { first } }
                    expectations1.to { achieve { second } }
                end
                it 'cannot be executed recursively within the event processing block' do
                    assert_raises(ExpectExecution::InvalidContext) do
                        expect_execution do
                            expect_execution {}
                        end.to {}
                    end
                end
                it 'cannot be executed recursively within the expectation block' do
                    assert_raises(ExpectExecution::InvalidContext) do
                        expect_execution.to do
                            expect_execution.to {}
                        end
                    end
                end
            end

            describe "#expect_execution_default_timeout" do
                it 'allows setting the default timeout' do
                    plan.add(task = Roby::Tasks::Simple.new)
                    tics = [Time.now]
                    self.expect_execution_default_timeout = 0.1
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution.to { emit task.start_event }
                    end
                    tics << Time.now
                    self.expect_execution_default_timeout = 0.5
                    assert_raises(Roby::Test::ExecutionExpectations::Unmet) do
                        expect_execution.to { emit task.start_event }
                    end
                    tics << Time.now

                    assert((0.05..0.2).include?(tics[1] - tics[0]))
                    assert((0.45..0.55).include?(tics[2] - tics[1]))
                end
            end

            describe '#add_expectations' do
                it 'adds a new expectation from within the event processing block' do
                    called = false
                    expect_execution do
                        add_expectations do
                            achieve { called = true }
                        end
                    end.to { }
                    assert called
                end
                it 'ignores the return values of expectations added this way' do
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
