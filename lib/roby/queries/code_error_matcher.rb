# frozen_string_literal: true

module Roby
    module Queries
        # Matcher for CodeError exceptions
        #
        # In addition to the LocalizedError properties, it allows to match
        # properties on the Ruby exception that has been thrown
        class CodeErrorMatcher < LocalizedErrorMatcher
            attr_reader :ruby_exception_class
            def initialize
                super
                @ruby_exception_class = ::Exception
                with_model(CodeError)
            end

            # Match the underlying ruby exception
            #
            # @param [#===,Class] matcher an object that can match an Exception
            #   object, usually an exception class
            def with_ruby_exception(matcher)
                with_original_exception(matcher)
                @ruby_exception_class = matcher
                self
            end

            # Match a CodeError without an original exception
            def without_ruby_exception
                with_ruby_exception(nil)
            end

            def ===(error)
                return false if !super

                ruby_exception_class === error.error
            end

            def to_s
                description = super
                if ruby_exception_class
                    description.concat(".with_ruby_exception(#{ruby_exception_class})")
                else
                    description.concat(".without_ruby_exception")
                end
            end

            def describe_failed_match(exception)
                if description = super
                    description
                elsif !(ruby_exception_class === exception.error)
                    if ruby_exception_class
                        "the underlying exception #{exception.error} does not match the expected #{ruby_exception_class}"
                    else
                        "there is an underlying exception (#{exception.error}) but the matcher expected none"
                    end
                end
            end
        end
    end
end
