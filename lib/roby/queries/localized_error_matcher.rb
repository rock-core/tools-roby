module Roby
    module Queries
        # Object that allows to specify generalized matches on a
        # Roby::LocalizedError object
        class LocalizedErrorMatcher < MatcherBase
            # @return [Class] the exception class that should be matched. It
            #   must be a subclass of LocalizedError, and is LocalizedError by
            #   default
            attr_reader :model
            # @return [#===] the object that will be used to match the error
            #   origin
            attr_reader :failure_point_matcher
            # @return [#===,nil] match object to validate the exception's
            #   ExeptionBase#original_exceptions
            attr_reader :original_exception_model

            def initialize
                super
                @model = LocalizedError
                @failure_point_matcher = Queries.any
                @original_exception_model = nil
            end

            # Specifies which subclass of LocalizedError this matcher should
            # look for
            # @return self
            def with_model(model)
                @model = model
                self
            end

            # Specifies that the exception object should have an
            # original_exception registered of the given model
            #
            # Set to nil to allow for no original exception at all
            def with_original_exception(model)
                @original_exception_model = model
                self
            end

            # Specifies a match on the error origin
            #
            # The resulting match is extended, i.e. a task matcher will match
            # the origin's task event if the origin itself is an event.
            #
            # @return self
            def with_origin(plan_object_matcher)
                @failure_point_matcher = plan_object_matcher.match
                if failure_point_matcher.respond_to?(:generalized?) && !plan_object_matcher.respond_to?(:generalized?)
                    failure_point_matcher.generalized
                end
                self
            end

            # @return [Boolean] true if the given execution exception object
            #   matches self, false otherwise
            def ===(exception)
                if !(model === exception)
                    return false
                end

                if original_exception_model
                    original_exception = exception.original_exceptions.
                        find { |e| original_exception_model === e }
                    if !original_exception
                        return false
                    end
                end

                if !exception.failed_task
                    if !(failure_point_matcher === exception.failed_generator)
                        return false
                    end
                elsif failure_point_matcher.respond_to?(:task_matcher)
                    if exception.failed_generator
                        return false if !(failure_point_matcher === exception.failed_generator)
                    else return false
                    end
                else
                    return false if !(failure_point_matcher === exception.failed_task)
                end

                original_exception || true
            end

            def describe_failed_match(exception)
                if !(model === exception)
                    return "exception model #{exception} does not match #{model}"
                end

                if original_exception_model
                    original_exception = exception.original_exceptions.
                        find { |e| original_exception_model === e }
                    if !original_exception
                        if exception.original_exceptions.empty?
                            return "expected one of the original exceptions to match #{original_exception_model}, but none are registered"
                        else
                            return "expected one of the original exceptions to match #{original_exception_model}, but got #{exception.original_exceptions.map(&:to_s).join(", ")}"
                        end
                    end
                end

                if !exception.failed_task
                    if !(failure_point_matcher === exception.failed_generator)
                        return "failure point #{exception.failed_generator} does not match #{failure_point_matcher}"
                    end
                elsif failure_point_matcher.respond_to?(:task_matcher)
                    if exception.failed_generator
                        if !(failure_point_matcher === exception.failed_generator)
                            return "failure point #{exception.failed_generator} does not match #{failure_point_matcher}"
                        end
                    else
                        return "exception reports no failure generator but was expected to"
                    end
                elsif !(failure_point_matcher === exception.failed_task)
                    return "failure point #{exception.failed_task} does not match #{failure_point_matcher}"
                end
                nil
            end

            def to_s
                description = "#{model}.with_origin(#{failure_point_matcher})"
                if original_exception_model
                    description.concat(".with_original_exception(#{original_exception_model})")
                end
                description
            end

            def matches_task?(task)
                if failure_point_matcher.respond_to?(:task_matcher)
                    failure_point_matcher.task_matcher == task
                else failure_point_matcher === task
                end
            end

            match_predicate :fatal?
            
            def to_execution_exception_matcher
                Roby::Queries::ExecutionExceptionMatcher.new.with_exception(self)
            end
        end
    end
end


