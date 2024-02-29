# frozen_string_literal: true

require "roby/test/expect_execution"

module Roby
    module Test
        # Handlers for minitest-based tests
        #
        # They mainly "tune" the default minitest behaviour to match some of the
        # Roby idioms as e.g. using pretty-print to format exception messages
        module MinitestHelpers
            include ExpectExecution

            def roby_find_matching_exception(expected, exception)
                queue = [exception]
                seen  = Set.new
                until queue.empty?
                    e = queue.shift
                    next if seen.include?(e)

                    seen << e
                    if expected.any? { |expected_e| e.kind_of?(expected_e) }
                        return e
                    end

                    if e.respond_to?(:original_exceptions)
                        queue.concat(e.original_exceptions)
                    end
                end
                nil
            end

            def assert_raises(*exp, display_exceptions: false, return_original_exception: false, &block)
                if plan.executable?
                    # Avoid having it displayed by the execution engine. We're going
                    # to display any unexpected exception anyways
                    display_exceptions_enabled, plan.execution_engine.display_exceptions =
                        plan.execution_engine.display_exceptions?, display_exceptions
                end

                msg = exp.pop if String === exp.last

                matchers = exp.dup
                exp = exp.map do |e|
                    if e.kind_of?(Queries::LocalizedErrorMatcher)
                        e.model
                    else
                        e
                    end
                end

                # The caller expects a non-Roby exception. It is going to be
                # wrapped in a LocalizedError, so make sure we properly
                # process it
                begin
                    yield
                rescue *exp => e
                    if matchers.any? { |m| m === e }
                        assert_exception_can_be_pretty_printed(e)
                        return e
                    else
                        flunk("#{matchers.map(&:to_s).join(', ')} exceptions expected, not #{e.class}")
                    end
                rescue ::Exception => root_e # rubocop:disable Naming/RescuedExceptionsVariableName
                    assert_exception_can_be_pretty_printed(root_e)
                    all = Roby.flatten_exception(root_e)
                    if actual_e = all.find { |e| matchers.any? { |expected_e| expected_e === e } }
                        if return_original_exception
                            return actual_e, root_e
                        else
                            return actual_e
                        end
                    end
                    actually_caught = roby_exception_to_string(*all)
                    flunk("#{exp.map(&:to_s).join(', ')} exceptions expected, not #{root_e.class} #{actually_caught}")
                end
                flunk("#{exp.map(&:to_s).join(', ')} exceptions expected but received nothing")
            ensure
                if plan.executable?
                    plan.execution_engine.display_exceptions =
                        display_exceptions_enabled
                end
            end

            def roby_exception_to_string(*queue)
                msg = String.new
                seen = Set.new
                while e = queue.shift
                    next if seen.include?(e)

                    seen << e
                    e_bt = Minitest.filter_backtrace(e.backtrace).join "\n    "
                    msg << "\n\n" << Roby.format_exception(e).join("\n") + "\n    #{e_bt}"

                    queue.concat(e.original_exceptions) if e.respond_to?(:original_exceptions)
                end
                msg
            end

            def register_failure(e)
                case e
                when Assertion
                    self.failures << e
                else
                    self.failures << Minitest::UnexpectedError.new(e)
                end
            end

            # Overloaded from minitest
            #
            # Minitest requires assertions to be marshallable, which this method
            # checks. This is unnecessarily restrictive for us, so we
            # reimplement this method to bypass that check
            #
            # It means that we can't use minitest's client/server tests, but
            # that's not something we do.
            def sanitize_exception(e)
                e
            end
        end
    end
end
