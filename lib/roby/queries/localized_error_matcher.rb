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

            def initialize
                super
                @model = LocalizedError
                @failure_point_matcher = Queries.any
            end

            # Specifies which subclass of LocalizedError this matcher should
            # look for
            # @return self
            def with_model(model)
                @model = model
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
                self
            end

            # @return [Boolean] true if the given execution exception object
            #   matches self, false otherwise
            def ===(exception)
                if !(model === exception)
                    return false
                end

                if !exception.failed_task
                    # Cannot match exceptions assigned to free events
                    return false
                elsif failure_point_matcher.respond_to?(:task_matcher)
                    if exception.failed_generator
                        return false if !(failure_point_matcher === exception.failed_generator)
                    else return false
                    end
                else
                    return false if !(failure_point_matcher === exception.failed_task)
                end

                true
            end

            match_predicate :fatal?
            
            def to_execution_exception_matcher
                Roby::Queries::ExecutionExceptionMatcher.new.with_exception(self)
            end
        end
    end
end


