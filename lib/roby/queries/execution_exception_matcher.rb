module Roby
    module Queries
        # Object that allows to specify generalized matches on a Roby::ExecutionException
        # object
        class ExecutionExceptionMatcher
            # An object that will be used to match the actual (Ruby) exception
            # @return [LocalizedErrorMatcher]
            attr_reader :exception_matcher
            # An object that will be used to match the exception origin
            # @return [Array<#===,TaskMatcher>]
            attr_reader :involved_tasks_matchers

            def initialize
                @exception_matcher = LocalizedErrorMatcher.new
                @involved_tasks_matchers = Array.new
                @expected_edges = nil
                @handled = nil
            end

            def handled(flag = true)
                @handled = flag
                self
            end

            def not_handled
                handled(false)
            end

            # Sets the exception matcher object
            def with_exception(exception_matcher)
                @exception_matcher = exception_matcher
                self
            end

            # (see LocalizedErrorMatcher#with_model)
            def with_model(exception_model)
                exception_matcher.with_model(exception_model)
                self
            end

            # (see LocalizedErrorMatcher#with_origin)
            def with_origin(plan_object_matcher)
                exception_matcher.with_origin(plan_object_matcher)
                self
            end

            # (see LocalizedErrorMatcher#fatal)
            def fatal
                exception_matcher.fatal
                self
            end

            def with_trace(*edges)
                @expected_edges = edges.each_slice(2).map { |a, b| [a, b, nil] }.to_set
                self
            end

            # Matched exceptions must have a task in their trace that matches
            # the given task matcher
            #
            # @param [TaskMatcher] task_matcher
            def involving(task_matcher)
                involved_tasks_matchers << origin_matcher
                self
            end

            def to_s
                PP.pp(self, "")
            end

            def pretty_print(pp)
                pp.text "ExecutionException("
                exception_matcher.pretty_print(pp)
                pp.text ")"
                if !involved_tasks_matchers.empty?
                    pp.text ".involving("
                    pp.nest(2) do
                        involved_tasks_matchers.each do |m|
                            pp.breakable
                            m.pretty_print(pp)
                        end
                    end
                    pp.text ")"
                end
                if @expected_edges
                    pp.text ".with_trace("
                    pp.nest(2) do
                        @expected_edges.each do |a, b, _|
                            pp.breakable
                            pp.text "#{a} => #{b}"
                        end
                    end
                    pp.text ")"
                end
                if !@handled.nil?
                    if @handled
                        pp.text ".handled"
                    else
                        pp.text ".not_handled"
                    end
                end
            end

            # @return [Boolean] true if the given execution exception object
            #   matches self, false otherwise
            def ===(exception)
                if !exception.respond_to?(:to_execution_exception)
                    return false
                end
                exception = exception.to_execution_exception
                exception_matcher === exception.exception &&
                    involved_tasks_matchers.all? { |m| exception.trace.any? { |t| m === t } } &&
                    (!@expected_edges || (@expected_edges == exception.trace.each_edge.to_set)) &&
                    (@handled.nil? || !(@handled ^ exception.handled?))
            end

            def describe_failed_match(exception)
                if !(exception_matcher === exception.exception)
                    return exception_matcher.describe_failed_match(exception.exception)
                elsif missing_involved_task = involved_tasks_matchers.find { |m| exception.trace.none? { |t| m === t } }
                    return "#{missing_involved_task} cannot be found in the exception trace\n  #{exception.trace.map(&:to_s).join("\n  ")}"
                end
            end

            def matches_task?(task)
                involved_tasks_matchers.all? { |m| m === task } &&
                    exception_matcher.matches_task?(task)
            end

            def to_execution_exception_matcher
                self
            end
        end
    end
end
