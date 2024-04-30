# frozen_string_literal: true

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
                @emitted = false
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
                if model.respond_to?(:exception_matcher)
                    @original_exception_model = model.exception_matcher
                else
                    @original_exception_model = model
                end
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

            # If the failure point matcher is a generator matcher, require that
            # the failure origin is an actual emission
            def emitted
                @emitted = true
                self
            end

            # @return [Boolean] true if the given execution exception object
            #   matches self, false otherwise
            def ===(exception)
                return false unless model === exception
                return false if @emitted && !exception.failed_event

                if original_exception_model
                    original_exception = exception.original_exceptions
                                                  .find { |e| original_exception_model === e }
                    unless original_exception
                        return false
                    end
                end

                if !exception.failed_task
                    return false unless failure_point_matcher === exception.failed_generator
                elsif failure_point_matcher.respond_to?(:task_matcher)
                    return false unless (failed_generator = exception.failed_generator)
                    return false unless failure_point_matcher === failed_generator
                elsif !(failure_point_matcher === exception.failed_task)
                    return false
                end

                original_exception || true
            end

            def describe_failed_match(exception)
                unless model === exception
                    return "exception model #{exception} does not match #{model}"
                end

                if original_exception_model
                    original_exception = exception.original_exceptions
                                                  .find { |e| original_exception_model === e }
                    unless original_exception
                        if exception.original_exceptions.empty?
                            return "expected one of the original exceptions "\
                                   "to match #{original_exception_model}, "\
                                   "but none are registered"
                        else
                            original_exceptions_s =
                                exception.original_exceptions.map(&:to_s).join(", ")
                            return "expected one of the original exceptions to "\
                                   "match #{original_exception_model}, but got "\
                                   "#{original_exceptions_s}"
                        end
                    end
                end

                if !exception.failed_task
                    unless failure_point_matcher === exception.failed_generator
                        return "failure point #{exception.failed_generator} does not "\
                               "match #{failure_point_matcher}"
                    end
                elsif failure_point_matcher.respond_to?(:task_matcher)
                    if exception.failed_generator
                        unless failure_point_matcher === exception.failed_generator
                            return "failure point #{exception.failed_generator} does "\
                                   "not match #{failure_point_matcher}"
                        end
                    else
                        return "exception reports no failure generator "\
                               "but was expected to"
                    end
                elsif !(failure_point_matcher === exception.failed_task)
                    return "failure point #{exception.failed_task} does not "\
                           "match #{failure_point_matcher}"
                end
                nil
            end

            def to_s
                description = "#{model}.with_origin(#{failure_point_matcher})"
                if original_exception_model
                    description += ".with_original_exception(#{original_exception_model})"
                end
                description
            end

            def matches_task?(task)
                if failure_point_matcher.respond_to?(:task_matcher)
                    failure_point_matcher.task_matcher == task
                else
                    failure_point_matcher === task
                end
            end

            match_predicate :fatal?

            def to_execution_exception_matcher
                Roby::Queries::ExecutionExceptionMatcher.new.with_exception(self)
            end
        end
    end
end
