# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Queries
        describe CodeErrorMatcher do
            before do
                plan.add(@task = Roby::Task.new)
            end

            it "matches a plain CodeError with exception as-is" do
                error = CodeError.new(Exception.new, @task)
                matcher = CodeErrorMatcher.new
                assert_operator matcher, :===, error
            end

            it "matches a plain CodeError without exception as-is" do
                error = CodeError.new(nil, @task)
                matcher = CodeErrorMatcher.new
                assert_operator matcher, :===, error
            end

            it "matches a CodeError whose ruby error matches" do
                error_m = Class.new(StandardError)
                error = CodeError.new(error_m.new, @task)
                matcher = CodeErrorMatcher.new.with_ruby_exception(error_m)
                assert_operator matcher, :===, error
            end

            it "does not match a CodeError whose ruby error does not match" do
                error_m = Class.new(StandardError)
                error = CodeError.new(StandardError.new, @task)
                matcher = CodeErrorMatcher.new.with_ruby_exception(error_m)
                refute_operator matcher, :===, error
            end

            it "handles CodeError without original exception" do
                error = CodeError.new(nil, @task)
                matcher = CodeErrorMatcher.new.without_ruby_exception
                assert_operator matcher, :===, error
            end

            it "does not match CodeError with ruby exception if "\
               "without_ruby_exception was set" do
                error = CodeError.new(StandardError.new, @task)
                matcher = CodeErrorMatcher.new.without_ruby_exception
                refute_operator matcher, :===, error
            end

            it "lets itself be converted to string" do
                matcher = CodeErrorMatcher
                          .new.with_origin(@task)
                          .with_ruby_exception(StandardError)
                expected = "Roby::CodeError.with_origin(#{@task})"\
                           ".with_original_exception(StandardError)"\
                           ".with_ruby_exception(StandardError)"
                assert_equal expected, matcher.to_s
            end

            it "describes a failure to match the expected ruby exception" do
                error_m = Class.new(StandardError)
                error = CodeError.new(StandardError.new, @task)
                matcher = CodeErrorMatcher.new.with_ruby_exception(error_m)
                description = matcher.describe_failed_match(error)
                expected = "expected one of the original exceptions to match "\
                           "#{error_m}, but got StandardError"
                assert_equal expected, description
            end

            it "has special formatting for an error without ruby exception" do
                matcher = CodeErrorMatcher
                          .new.with_origin(@task)
                          .without_ruby_exception
                expected = "Roby::CodeError.with_origin(#{@task})"\
                           ".without_ruby_exception"
                assert_equal expected, matcher.to_s
            end

            it "describes a failure for having a ruby exception while "\
               "none was expected" do
                error = CodeError.new(StandardError.new, @task)
                matcher = CodeErrorMatcher.new.without_ruby_exception
                description = matcher.describe_failed_match(error)
                expected = "there is an underlying exception (StandardError) but "\
                           "the matcher expected none"
                assert_equal expected, description
            end
        end
    end
end
