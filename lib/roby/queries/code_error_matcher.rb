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
                @ruby_exception_class = matcher
                self
            end

            def ===(error)
                return false if !super
                ruby_exception_class === error.error
            end
        end
    end
end

