# frozen_string_literal: true

require "roby/test/self"

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
                            expect_execution {}
                        end.to {}
                    end
                end
                it "cannot be executed recursively within the expectation block" do
                    assert_raises(ExpectExecution::InvalidContext) do
                        expect_execution.to do
                            expect_execution.to {}
                        end
                    end
                end
            end

            describe "#expect_execution_default_timeout" do
                it "allows setting the default timeout" do
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

            describe "#add_expectations" do
                it "adds a new expectation from within the event processing block" do
                    called = false
                    expect_execution do
                        add_expectations do
                            achieve { called = true }
                        end
                    end.to {}
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

            it "properly formats an exception "\
               "when it is the reason of an unachievable message" do
                plan.add(task = Tasks::Simple.new)
                exception =
                    begin
                        raise "something"
                    rescue RuntimeError => e
                        e
                    end

                begin
                    expect_execution { task.success_event.unreachable!(exception) }
                        .to { emit task.success_event }
                rescue ExecutionExpectations::Unmet => unmet # rubocop:disable Lint/SuppressedException,Naming/RescuedExceptionsVariableName
                end

                expected = <<~MSG
                    1 unmet expectations
                    Roby::Tasks::Simple<id:XX>(id:XX)/success should be emitted, but it did not because of something (RuntimeError)

                      test/test/test_expect_execution.rb:XXX:in `block (2 levels) in <module:Test>'
                MSG

                assert_error_message_start_with(expected, unmet.message)
            end

            it "properly formats an exception when it is the context of an event "\
               "that is the reason the expectation is unmet" do
                plan.add(task = Tasks::Simple.new)
                task.poll { raise "something" }
                begin
                    expect_execution { task.start! }
                        .to { emit task.success_event }
                rescue ExecutionExpectations::Unmet => unmet # rubocop:disable Lint/SuppressedException,Naming/RescuedExceptionsVariableName
                end

                expected = <<~MSG
                    1 unmet expectations
                    Roby::Tasks::Simple<id:XX>(id:XX)/success should be emitted, but it did not because of event 'internal_error' emitted at [XX] from
                      Roby::Tasks::Simple<id:XX>
                        no owners
                        arguments:
                          id:XX
                      Roby::CodeError: user code raised an exception Roby::Tasks::Simple<id:XX>
                        no owners
                        arguments:
                          id:XX
                      Roby::CodeError: user code raised an exception Roby::Tasks::Simple<id:XX>
                        no owners
                        arguments:
                          id:XX
                      something (RuntimeError)

                        test/test/test_expect_execution.rb:XXX:in `block (3 levels) in <module:Test>'
                MSG

                assert_error_message_start_with(expected, unmet.message)
            end

            def normalize_error_message(msg)
                msg.gsub(/id:\s*"?\d+"?/, "id:XX")
                   .gsub(/\[[\d:.]* @\d+\]/, "[XX]")
                   .gsub(/^\s+$/, "")
                   .gsub(/\.rb:\d+:/, ".rb:XXX:")
                   .gsub(%r{/.*tools/roby/}, "") # paths may be absolute or relative
            end

            def assert_error_message_start_with(expected, actual)
                actual = normalize_error_message(actual)
                actual_dbg = actual.split("\n").map(&:inspect).join("\n")
                expected_dbg = expected.split("\n").map(&:inspect).join("\n")
                assert actual.start_with?(expected),
                       "expected\n```\n#{actual_dbg}\n```\nto start with\n"\
                       "```\n#{expected_dbg}\n```"
            end
        end
    end
end
