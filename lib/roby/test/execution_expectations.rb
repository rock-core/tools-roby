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

            def self.format_propagation_info(propagation_info, indent: 0)
                PP.pp(propagation_info).split("\n").join("\n" + " " * indent)
            end

            class Unmet < Minitest::Assertion
                def initialize(expectations_with_explanations, propagation_info)
                    @expectations = expectations_with_explanations
                    @propagation_info = propagation_info
                end

                def pretty_print(pp)
                    pp.text "#{@expectations.size} unmet expectations"
                    @expectations.each do |exp, explanation|
                        pp.breakable
                        exp.pretty_print(pp)
                        if explanation
                            pp.text " because of "
                            explanation.pretty_print(pp)
                        end
                    end
                    if !@propagation_info.empty?
                        pp.breakable
                        @propagation_info.pretty_print(pp)
                    end
                end

                def to_s
                    PP.pp(self, "", 1).strip
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

            def have_internal_error(task, original_exception)
                emit task.internal_error_event
                have_handled_error_matching original_exception.match.with_origin(task)
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

            def with_execution_engine_setup
                engine = @plan.execution_engine
                current_scheduler = engine.scheduler
                current_scheduler_state = engine.scheduler.enabled?
                current_display_exceptions = engine.display_exceptions?
                if !@display_exceptions.nil?
                    engine.display_exceptions = @display_exceptions
                end
                if !@scheduler.nil?
                    if @scheduler != true && @scheduler != false
                        engine.scheduler = @scheduler
                    else
                        engine.scheduler.enabled = @scheduler
                    end
                end

                yield
            ensure
                engine.scheduler = current_scheduler
                engine.scheduler.enabled = current_scheduler_state
                engine.display_exceptions = current_display_exceptions
            end

            # Verify that executing the given block in event propagation context
            # will cause the expectations to be met
            def verify(&block)
                all_propagation_info = ExecutionEngine::PropagationInfo.new
                timeout_deadline = Time.now + @timeout

                begin
                    engine = @plan.execution_engine
                    engine.start_new_cycle
                    propagation_info = with_execution_engine_setup do
                        engine.process_events(garbage_collect_pass: @garbage_collect, &block)
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

                    if @validate_unexpected_errors
                        validate_has_no_unexpected_error(all_propagation_info)
                    end

                    remaining_timeout = timeout_deadline - Time.now
                    break if remaining_timeout < 0

                    if engine.has_waiting_work? && @join_all_waiting_work
                        _, propagation_info = with_execution_engine_setup do
                            engine.join_all_waiting_work(timeout: remaining_timeout)
                        end
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
                            obj.return_object
                        else
                            obj
                        end
                    end
                else
                    obj = @return_objects
                    if obj.respond_to?(:return_object)
                        obj.return_object
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
                        exceptions_context = ev.context.find_all { |obj| obj.kind_of?(Exception) }
                        !exceptions_context.any? { |exception| @expectations.any? { |expectation| expectation.relates_to_error?(exception) } }
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
                    !exp.update_match(all_errors)
                end
            end

            # Null implementation of an expectation
            class Expectation
                attr_reader :backtrace

                def initialize(backtrace)
                    @backtrace = backtrace
                end

                # Verifies whether the expectation is met at this point
                #
                # This method is meant to update 
                def update_match(propagation_info)
                    true
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

                def update_match(propagation_info)
                    @emitted_events = propagation_info.emitted_events.
                        find_all { |ev| ev.generator == @generator }
                    @emitted_events.empty?
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

                def update_match(propagation_info)
                    @emitted_events = propagation_info.emitted_events.
                        find_all { |ev| ev.generator == @generator }
                    !@emitted_events.empty?
                end

                def return_object
                    @emitted_events.first
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

            class ErrorExpectation < Expectation
                def initialize(matcher, backtrace)
                    super(backtrace)
                    @matcher = matcher.to_execution_exception_matcher
                end

                def update_match(exceptions)
                    @matched_execution_exceptions = exceptions.
                        find_all { |error| @matcher === error }
                    @matched_exceptions = @matched_execution_exceptions.
                        map(&:exception).to_set
                    @matched_exceptions = @matched_exceptions.flat_map do |e|
                        Roby.flatten_exception(e).to_a
                    end.to_set
                    !@matched_execution_exceptions.empty?
                end

                def relates_to_error?(execution_exception)
                    @matched_execution_exceptions.include?(execution_exception) ||
                        Roby.flatten_exception(execution_exception.exception).
                            any? { |e| @matched_exceptions.include?(e) }
                end

                def return_object
                    @matched_execution_exceptions.first
                end
            end

            class HaveErrorMatching < ErrorExpectation
                def update_match(propagation_info)
                    super(propagation_info.exceptions)
                end

                def to_s
                    "has error matching #{@matcher}"
                end
            end

            class HaveHandledErrorMatching < ErrorExpectation
                def update_match(propagation_info)
                    super(propagation_info.handled_errors.map(&:first))
                end

                def to_s
                    "has handled error matching #{@matcher}"
                end
            end

            class Quarantine < Expectation
                def initialize(task, backtrace)
                    super(backtrace)
                    @task = task
                end

                def update_match(propagation_info)
                    @task.quarantined?
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

                def update_match(propagation_info)
                    @generator.unreachable?
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
                    if @reason && @reason.respond_to?(:to_execution_exception_matcher)
                        @reason = @reason.to_execution_exception_matcher
                        @related_error_matcher = LocalizedError.match.with_original_exception(@reason).
                            to_execution_exception_matcher
                    end
                end

                def update_match(propagation_info)
                    if !@task.failed_to_start?
                        false
                    elsif !@reason
                        true
                    else
                        @reason === @task.failure_reason
                    end
                end

                def unachievable?(propagation_info)
                    if @reason && @task.failed_to_start?
                        !(@reason === @task.failure_reason)
                    end
                end

                def relates_to_error?(exception)
                    if @reason
                        (@reason === exception) || (@related_error_matcher === exception)
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

