module Roby
    module Test
        # Underlying implementation for Roby's when do end.expect ... feature
        class ExecutionExpectations
            # Parse a expect { } block into an Expectation object
            #
            # @return [Expectation]
            def self.parse(test, plan, &block)
                new(test, plan).parse(&block)
            end

            def parse(&block)
                @return_objects = instance_eval(&block)
                self
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

            def self.format_propagation_info(propagation_info)
                result = []
                if !propagation_info.emitted_events.empty?
                    result << "received #{propagation_info.emitted_events} events:\n  " +
                        propagation_info.emitted_events.map { |ev| ev.to_s }.join("\n  ")
                end
                exceptions = propagation_info.exceptions
                if !exceptions.empty?
                    result << "#{exceptions.size} exceptions:\n  " +
                        exceptions.map { |e| PP.pp(e, "").split("\n").join("\n    ") }.join("\n  ")
                end
                result.join("\n")
            end

            class Unmet < Minitest::Assertion
                def initialize(expectations_with_explanations, propagation_info)
                    @expectations = expectations_with_explanations
                    @propagation_info = propagation_info
                end

                def to_s
                    propagation_info = ExecutionExpectations.format_propagation_info(@propagation_info)
                    if !propagation_info.empty?
                        propagation_info = "\n" + propagation_info
                    end
                    "#{@expectations.size} unmet expectations\n" +
                    @expectations.map do |exp, explanation|
                        exp = PP.pp(exp, "").chomp
                        if explanation
                            exp += " because of " + PP.pp(explanation, "").chomp
                        end
                        exp
                    end.join("\n") + propagation_info
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
                expectation
            end

            # Expect that an event should be emitted
            def not_emit(generator, backtrace: caller(1))
                add_expectation(NotEmit.new(generator, backtrace))
                nil
            end

            def emit(generator, backtrace: caller(1))
                add_expectation(Emit.new(generator, backtrace))
            end

            def quarantine(task, backtrace: caller(1))
                add_expectation(Quarantine.new(task, backtrace))
                nil
            end

            def fail_to_start(task, reason: nil, backtrace: caller(1))
                add_expectation(FailsToStart.new(task, reason, backtrace))
                nil
            end

            def finish(task, backtrace: caller(1))
                emit task.start_event, backtrace: backtrace if !task.running?
                emit task.stop_event, backtrace: backtrace
                nil
            end

            def keep_running(task, backtrace: caller(1))
                emit task.start_event, backtrace: backtrace if !task.running?
                not_emit task.stop_event, backtrace: backtrace
                nil
            end

            def have_error_matching(matcher, backtrace: caller(1))
                add_expectation(HaveErrorMatching.new(matcher, backtrace))
            end

            def have_handled_error_matching(matcher, backtrace: caller(1))
                add_expectation(HaveHandledErrorMatching.new(matcher, backtrace))
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
                        raise Unmet.new(unachievable, all_propagation_info)
                    end

                    remaining_timeout = timeout_deadline - Time.now
                    break if remaining_timeout < 0

                    if engine.has_waiting_work? && @join_all_waiting_work
                        _, propagation_info = engine.join_all_waiting_work(timeout: remaining_timeout)
                        all_propagation_info.merge(propagation_info)
                    elsif unmet.empty?
                        break
                    end

                    engine.cycle_end(Hash.new)
                    block = nil
                end while @wait_until_timeout || (engine.has_waiting_work? && @join_all_waiting_work)

                unmet = find_all_unmet_expectations(all_propagation_info)
                if !unmet.empty?
                    raise Unmet.new(unmet, all_propagation_info)
                end

                if @validate_unexpected_errors
                    validate_has_no_unexpected_error(all_propagation_info)
                end

                if @return_objects.respond_to?(:to_ary)
                    @return_objects.map do |obj|
                        if obj.respond_to?(:return_object)
                            obj.return_object(all_propagation_info)
                        else
                            obj
                        end
                    end
                else
                    obj = @return_objects
                    if obj.respond_to?(:return_object)
                        obj.return_object(all_propagation_info)
                    else
                        obj
                    end
                end
            end

            def validate_has_no_unexpected_error(propagation_info)
                unexpected_errors = propagation_info.exceptions.find_all do |e|
                    unexpected_error?(e)
                end

                # Look for internal_error_event, which is how the tasks report
                # on their internal errors
                internal_errors = propagation_info.emitted_events.find_all do |ev|
                    if ev.generator.respond_to?(:symbol) && ev.generator.symbol == :internal_error
                        @expectations.none? do |exp|
                            exp.kind_of?(Emit) && exp.generator == ev.generator
                        end
                    end
                end

                unexpected_errors += internal_errors.flat_map { |ev| ev.context }
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
                attr_reader :generator

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
                    !return_object(propagation_info)
                end

                def return_object(propagation_info)
                    propagation_info.emitted_events.
                        find { |ev| ev.generator == @generator }
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

            class HaveErrorMatching < Expectation
                def initialize(matcher, backtrace)
                    super(backtrace)
                    @matcher = matcher.to_execution_exception_matcher
                end

                def relates_to_error?(error)
                    @matcher === error
                end

                def unmet?(propagation_info)
                    !return_object(propagation_info)
                end

                def return_object(propagation_info)
                    propagation_info.exceptions.
                        find { |error| @matcher === error }
                end

                def to_s
                    "has error matching #{@matcher}"
                end
            end

            class HaveHandledErrorMatching < Expectation
                def initialize(matcher, backtrace)
                    super(backtrace)
                    @matcher = matcher
                end

                def relates_to_error?(error)
                    @matcher === error
                end

                def unmet?(propagation_info)
                    !return_object(propagation_info)
                end

                def return_object(propagation_info)
                    propagation_info.handled_errors.
                        none? { |error| @matcher === error }
                end

                def to_s
                    "has error matching #{@matcher}"
                end
            end

            class Quarantine < Expectation
                def initialize(task, backtrace)
                    super(backtrace)
                    @task = task
                end

                def unmet?(propagation_info)
                    !@task.quarantined?
                end

                def to_s
                    "#{@task} is quarantined"
                end
            end

            class MakeUnreachable < Expectation
                def initialize(generator, backtrace)
                    super(backtrace)
                    @generator = generator
                end

                def unmet?(propagation_info)
                    !@generator.unreachable?
                end

                def to_s
                    "#{@generator} is unreachable"
                end
            end

            class FailsToStart < Expectation
                def initialize(task, reason, backtrace)
                    super(backtrace)
                    @task = task
                    @reason = reason
                end

                def unmet?(propagation_info)
                    if !@task.failed_to_start?
                        true
                    elsif @reason
                        !(@reason === @task.failure_reason)
                    end
                end

                def unachievable?(propagation_info)
                    if @reason && @task.failed_to_start?
                        !(@reason === @task.failure_reason)
                    end
                end

                def explain_unachievable(propagation_info)
                    "#{@task.failure_reason} does not match #{@reason}"
                end

                def to_s
                    "#{@generator} has failed to start"
                end
            end
        end
    end
end

