module Roby
    module Test
        # Underlying implementation for Roby's when do end.expect ... feature
        class ExecutionExpectations
            # Parse a expect { } block into an Expectation object
            #
            # @return [Expectation]
            def self.parse(test, plan, &block)
                expectations = new(test, plan)
                expectations.instance_eval(&block)
                expectations
            end

            def initialize(test, plan)
                @test = test
                @plan = plan

                @expectations = Array.new

                @scheduler = false
                @timeout = 5
                @join_all_waiting_work = true
                @wait_until_timeout = true
                @garbage_collect = false
                @validate_unexpected_errors = true
                @display_exceptions = false
            end

            def respond_to_missing?(m, include_private)
                @test.respond_to?(m) || super
            end

            def method_missing(m, *args, &block)
                if @test.respond_to?(m)
                    @test.public_send(m, *args, &block)
                else super
                end
            end

            class Unmet < Minitest::Assertion
                def initialize(expectations_with_explanations)
                    @expectations = expectations_with_explanations
                end

                def to_s
                    "#{@expectations.size} unmet expectations\n" +
                    @expectations.map do |exp, explanation|
                        exp = PP.pp(exp, "").chomp
                        if explanation
                            exp += " because of " + PP.pp(explanation, "").chomp
                        end
                        exp
                    end.join("\n")
                end
            end

            class Timeout < Minitest::Assertion
                def initialize(expectations_with_explanations)
                    @expectations = expectations_with_explanations
                end

                def to_s
                    "timed out waiting for #{@expectations.size} expectations\n" +
                    @expectations.map do |exp, explanation|
                        exp = PP.pp(exp, "").chomp
                        if explanation
                            exp += " because of " + PP.pp(explanation, "").chomp
                        end
                        exp
                    end.join("\n")
                end
            end

            class UnexpectedErrors < Minitest::Assertion
                def initialize(errors)
                    @errors = errors
                end

                def to_s
                    "#{@errors.size} unexpected errors\n" +
                    @errors.map do |e|
                        Roby.format_exception(e).join("\n")
                    end.join("\n")
                end
            end

            # How long will the test wait either for asynchronous jobs (if
            # #wait_until_timeout is false) or until it succeeds (if
            # #wait_until_timeout is true)
            #
            # The default is 5s
            dsl_attribute :timeout

            # How long will the test wait for asynchronous jobs until it fails
            #
            # The default is 5s
            dsl_attribute :wait_until_timeout

            # Whether the expectation test should wait for asynchronous work to
            # finish between event propagations
            #
            # The default is true
            dsl_attribute :join_all_waiting_work

            # Whether the scheduler should be active
            #
            # The default is false
            dsl_attribute :scheduler

            # Whether a garbage collection pass should be run
            #
            # The default is false
            dsl_attribute :garbage_collect

            # Whether the expectations will pass if exceptions are propagated
            # that are not explicitely expected
            #
            # The default is true
            dsl_attribute :validate_unexpected_errors

            # Whether exceptions should be displayed by the execution engine
            #
            # The default is false
            dsl_attribute :display_exceptions

            # Add a new expectation to be run during {#verify}
            def add_expectation(expectation)
                @expectations << expectation
            end

            # Expect that an event should be emitted
            def not_emit(generator, backtrace: caller(1))
                add_expectation(NotEmit.new(generator, backtrace))
            end

            def emit(generator, backtrace: caller(1))
                add_expectation(Emit.new(generator, backtrace))
            end

            def finish(task, backtrace: caller(1))
                emit task.start_event, backtrace: backtrace if !task.running?
                emit task.stop_event, backtrace: backtrace
            end

            def keep_running(task, backtrace: caller(1))
                emit task.start_event, backtrace: backtrace if !task.running?
                not_emit task.stop_event, backtrace: backtrace
            end

            def has_error_matching(matcher, backtrace: caller(1))
                add_expectation(HasErrorMatching.new(matcher, backtrace))
            end

            # Verify that executing the given block in event propagation context
            # will cause the expectations to be met
            def verify(&block)
                all_propagation_info = ExecutionEngine::PropagationInfo.new
                timeout_deadline = Time.now + @timeout

                begin
                    engine = @plan.execution_engine
                    engine.start_new_cycle
                    propagation_info =
                        begin
                            current_scheduler_state = engine.scheduler.enabled?
                            current_display_exceptions = engine.display_exceptions?
                            if !@display_exceptions.nil?
                                engine.display_exceptions = @display_exceptions
                            end
                            if !@scheduler.nil?
                                engine.scheduler.enabled = @scheduler
                            end

                            engine.process_events(garbage_collect_pass: @garbage_collect, &block)
                        ensure
                            engine.scheduler.enabled = current_scheduler_state
                            engine.display_exceptions = current_display_exceptions
                        end

                    all_propagation_info.merge(propagation_info)

                    unmet = find_all_unmet_expectations(all_propagation_info)
                    unachievable = unmet.find_all { |expectation| expectation.unachievable?(all_propagation_info) }
                    if !unachievable.empty?
                        unachievable = unachievable.map do |expectation|
                            [expectation, expectation.explain_unachievable(all_propagation_info)]
                        end
                        raise Unmet.new(unachievable)
                    end

                    remaining_timeout = timeout_deadline - Time.now
                    if remaining_timeout < 0
                        raise Timeout.new(unmet)
                    end

                    if engine.has_waiting_work? && @join_all_waiting_work
                        engine.join_all_waiting_work(timeout: remaining_timeout)
                    elsif unmet.empty?
                        break
                    end

                    engine.cycle_end(Hash.new)
                    block = nil
                end while @wait_until_timeout || (engine.has_waiting_work? && @join_all_waiting_work)

                unmet = find_all_unmet_expectations(all_propagation_info)
                if !unmet.empty?
                    raise Unmet.new(unmet)
                end

                if @validate_unexpected_errors
                    validate_has_no_unexpected_error(all_propagation_info)
                end
            end

            def validate_has_no_unexpected_error(propagation_info)
                unexpected_errors = propagation_info.exceptions.find_all do |e|
                    unexpected_error?(e)
                end

                if !unexpected_errors.empty?
                    raise UnexpectedErrors.new(unexpected_errors)
                end
            end

            def unexpected_error?(error)
                @expectations.each do |expectation|
                    if expectation.relates_to_error?(error)
                        return false
                    elsif error.respond_to?(:original_exceptions)
                        error.original_exceptions.each do |orig_e|
                            if expectation.relates_to_error?(orig_e)
                                return false
                            end
                        end
                    end
                end
                true
            end

            def find_all_unmet_expectations(all_errors)
                @expectations.find_all do |exp|
                    exp.unmet?(all_errors)
                end
            end

            # Null implementation of an expectation
            class Expectation
                attr_reader :backtrace

                def initialize(backtrace)
                    @backtrace = backtrace
                end

                def unmet?(propagation_info)
                    false
                end
                def unachievable?(propagation_info)
                    false
                end
                def explain_unachievable(propagation_info)
                    nil
                end
                def relates_to_error?(error)
                    false
                end
            end

            class NotEmit < Expectation
                def initialize(generator, backtrace)
                    super(backtrace)
                    @generator = generator
                    @related_error_matcher = Queries::LocalizedErrorMatcher.new.
                        with_origin(@generator).
                        to_execution_exception_matcher
                end

                def to_s
                    "no emission of #{@generator}"
                end

                def unmet?(propagation_info)
                    propagation_info.emitted_events.
                        any? { |ev| ev.generator == @generator }
                end

                def unachievable?(propagation_info)
                    @generator.emitted?
                end

                def explain_unachievable(propagation_info)
                    @generator.last
                end

                def relates_to_error?(error)
                    @related_error_matcher === error
                end
            end

            class Emit < Expectation
                def initialize(generator, backtrace)
                    super(backtrace)
                    @generator = generator
                    @related_error_matcher = Queries::LocalizedErrorMatcher.new.
                        with_origin(@generator).
                        to_execution_exception_matcher
                end

                def to_s
                    "emission of #{@generator}"
                end

                def unmet?(propagation_info)
                    propagation_info.emitted_events.
                        none? { |ev| ev.generator == @generator }
                end

                def unachievable?(propagation_info)
                    @generator.unreachable?
                end

                def explain_unachievable(propagation_info)
                    @generator.unreachability_reason
                end

                def relates_to_error?(error)
                    @related_error_matcher === error
                end
            end

            class HasErrorMatching < Expectation
                def initialize(matcher, backtrace)
                    super(backtrace)
                    @matcher = matcher
                end

                def relates_to_error?(error)
                    @matcher === error
                end

                def unmet?(propagation_info)
                    propagation_info.exceptions.
                        none? { |error| @matcher === error }
                end

                def to_s
                    "has error matching #{@matcher}"
                end
            end
        end
    end
end

