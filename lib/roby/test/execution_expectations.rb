# frozen_string_literal: true

module Roby
    module Test
        # Underlying implementation for Roby's when do end.expect ... feature
        #
        # The expectation's documented return value are NOT the values returned
        # by the method itself, but the value that the user can expect out of
        # the expectation run.
        #
        # @example execute until a block returns true. The call returns the
        #     block's return value
        #   expect_execution.to do
        #     achieve { plan.num_tasks }
        #   end # => the number of tasks from the plan
        #
        # @example execute until an event was emitted and an error raised. The
        #     call will in this case return the error object and the emitted event
        #   expect_execution.to do
        #     event = emit task.start_event
        #     error = have_error_matching CodeError
        #     [error, event]
        #   end # => the pair (raised error, emitted event)
        #
        class ExecutionExpectations
            # @!group Expectations

            # Expect that an event is not emitted after the expect_execution block
            #
            # Note that only one event propagation pass is guaranteed to happen
            # before the "no emission" expectation is validated. I.e. this
            # cannot test for the non-existence of a delayed emission
            #
            # @return [nil]
            def not_emit(*generators, within: 0, backtrace: caller(1))
                generators.map do |generator|
                    if generator.kind_of?(EventGenerator)
                        add_expectation(
                            NotEmitGenerator.new(generator, backtrace, within: within)
                        )
                    else
                        add_expectation(
                            NotEmitGeneratorModel.new(
                                generator, backtrace, within: within
                            )
                        )
                    end
                end
            end

            # Expect that an event is emitted after the expect_execution block
            #
            # @param [EventGenerator,Queries::EventGeneratorMatcher] generator
            # @return [Event,[Event]]
            #
            # @overload emit(generator)
            #   @param [EventGenerator] generator the generator we're waiting
            #     the emission of
            #   @return [Event] the emitted event
            #
            # @overload emit(generator_query)
            #   @param [Queries::EventGeneratorMatcher] query a query that
            #     matches the event whose emission we're watching.
            #   @return [[Event]] all the events whose generator match the
            #     query
            #
            #   @example wait for the emission of the start event of any task of
            #       model MyTask. The call will return the emitted events that match
            #       this.
            #     expect_execution.to do
            #       emit find_tasks(MyTask).start_event
            #     end
            #
            def emit(*generators, backtrace: caller(1))
                return_values = generators.map do |generator|
                    if generator.kind_of?(EventGenerator)
                        add_expectation(EmitGenerator.new(generator, backtrace))
                    else
                        add_expectation(EmitGeneratorModel.new(generator, backtrace))
                    end
                end
                if return_values.size == 1
                    return_values.first
                else
                    return_values
                end
            end

            # Expect that the generator(s) become unreachable
            #
            # @param [Array<EventGenerator>] generators the generators that are
            #   expected to become unreachable
            # @return [Object,Array<Object>] if only one generator is provided,
            #   its unreachability reason. Otherwise, the unreachability reasons
            #   of all the generators, in the same order than the argument
            def become_unreachable(*generators, backtrace: caller(1))
                return_values = generators.map do |generator|
                    add_expectation(BecomeUnreachable.new(generator, backtrace))
                end
                if return_values.size == 1
                    return_values.first
                else
                    return_values
                end
            end

            # Expect that the generator(s) do not become unreachable
            #
            # @param [Array<EventGenerator>] generators the generators that are
            #   expected to not become unreachable
            def not_become_unreachable(*generators, backtrace: caller(1))
                generators.map do |generator|
                    add_expectation(NotBecomeUnreachable.new(generator, backtrace))
                end
            end

            # Expect that the given block is true during a certain amount of
            # time
            #
            # @param [Float] at_least_during the minimum duration in seconds. If
            #   zero, the expectations will run at least one execution cycle. The
            #   exact duration depends on the other expectations.
            # @yieldparam [ExecutionEngine::PropagationInfo]
            #   all_propagation_info all that happened during the propagations
            #   since the beginning of expect_execution block. It contains event
            #   emissions and raised/caught errors.
            # @yieldreturn [Boolean] expected to be true over duration seconds
            def maintain(
                at_least_during: 0, description: nil, backtrace: caller(1), &block
            )
                add_expectation(
                    Maintain.new(at_least_during, block, description, backtrace)
                )
            end

            # Expect that the given block returns true
            #
            # @yieldparam [ExecutionEngine::PropagationInfo]
            #   all_propagation_info all that happened during the propagations
            #   since the beginning of expect_execution block. It contains event
            #   emissions and raised/caught errors.
            # @yieldreturn the value that should be returned by the expectation
            def achieve(description: nil, backtrace: caller(1), &block)
                add_expectation(Achieve.new(block, description, backtrace))
            end

            # Expect that the given task fails to start
            #
            # @param [Task] task
            # @return [nil]
            def fail_to_start(task, reason: nil, backtrace: caller(1))
                add_expectation(FailsToStart.new(task, reason, backtrace))
            end

            # Expect that the given task starts
            #
            # @param [Task] task
            # @return [Event] the task's start event
            def start(task, backtrace: caller(1))
                emit task.start_event, backtrace: backtrace
            end

            # Expect that the given task either starts or is running, and does not stop
            #
            # The caveats of {#not_emit} apply to the "does not stop" part of
            # the expectation. This should usually be used in conjunction with a
            # synchronization point.
            #
            # @example task keeps running until action_task stops
            #   expect_execution.to do
            #     keep_running task
            #     finish action_task
            #   end
            #
            # @param [Task] task
            # @return [nil]
            def have_running(task, backtrace: caller(1)) # rubocop:disable Naming/PredicateName
                unless task.running?
                    start_emitted = emit(task.start_event, backtrace: backtrace)
                end

                [start_emitted, not_emit(task.stop_event)].compact
            end

            # Expect that the given task finishes
            #
            # @param [Task] task
            # @return [Event] the task's stop event
            def finish(task, backtrace: caller(1))
                unless task.running?
                    start_emitted = emit(task.start_event, backtrace: backtrace)
                end

                [start_emitted, emit(task.stop_event, backtrace: backtrace)].compact
            end

            # Expect that plan objects (task or event) are finalized
            #
            # @param [Array<PlanObject>] plan_objects
            # @return [nil]
            def finalize(*plan_objects, backtrace: caller(1))
                plan_objects.map do |plan_object|
                    add_expectation(Finalize.new(plan_object, backtrace))
                end
            end

            # Expect that plan objects (task or event) are not finalized
            #
            # @param [Array<PlanObject>] plan_objects
            # @return [nil]
            def not_finalize(*plan_objects, backtrace: caller(1))
                plan_objects.map do |plan_object|
                    add_expectation(NotFinalize.new(plan_object, backtrace))
                end
            end

            # Expect that the given task emits its internal_error event
            #
            # @param [Task] task
            # @return [Event] the emitted internal error event
            def have_internal_error(task, original_exception) # rubocop:disable Naming/PredicateName
                [have_handled_error_matching(original_exception.match.with_origin(task)),
                 emit(task.internal_error_event)]
            end

            # Expect that the given task is put in quarantine
            #
            # @param [Task] task
            # @return [nil]
            def quarantine(task, backtrace: caller(1))
                add_expectation(Quarantine.new(task, backtrace))
            end

            # Expect that the given promise finishes
            #
            # @param [Promise] promise
            # @return [nil]
            def finish_promise(promise, backtrace: caller(1))
                add_expectation(PromiseFinishes.new(promise, backtrace))
            end

            # Expect that an error is raised and not caught
            #
            # @param [#===] matcher an error matching object. These are usually
            #   obtained by calling {Exception.match} on an exception class and
            #   then refining the match by using the
            #   {Queries::LocalizedErrorMatcher} AP (see example above)I
            # @return [ExecutionException] the matched exception
            #
            # @example expect that a {ChildFailedError} is raised from 'task'
            #   expect_execution.to do
            #     have_error_matching Roby::ChildFailedError.match.
            #       with_origin(task)
            #   end
            def have_error_matching(matcher, backtrace: caller(1)) # rubocop:disable Naming/PredicateName
                add_expectation(HaveErrorMatching.new(matcher, backtrace))
            end

            # Expect that an error is raised and caught
            #
            # @param [#===] matcher an error matching object. These are usually
            #   obtained by calling {Exception.match} on an exception class and
            #   then refining the match by using the
            #   {Queries::LocalizedErrorMatcher} API (see example above)
            # @return [ExecutionException] the matched exception
            #
            # @example expect that a {ChildFailedError} is raised from 'task' and handled
            #   expect_execution.to do
            #     have_handled_error_matching Roby::ChildFailedError.match.
            #       with_origin(task)
            #   end
            def have_handled_error_matching(matcher, backtrace: caller(1)) # rubocop:disable Naming/PredicateName
                add_expectation(HaveHandledErrorMatching.new(matcher, backtrace))
            end

            # Expect that a framework error is added
            #
            # Framework errors are errors that are raised outside of user code.
            # They are fatal inconsistencies, and cause the whole Roby instance
            # to quit forcefully
            #
            # Unlike with {#have_error_matching} and
            # {#have_handled_error_matching}, the error is rarely a
            # LocalizedError. For simple exceptions, one can simply use the
            # exception class to match.
            def have_framework_error_matching(error, backtrace: caller(1)) # rubocop:disable Naming/PredicateName
                add_expectation(HaveFrameworkError.new(error, backtrace))
            end

            # Given another predicate, ignore all errors related to this predicate but
            # do not expect the predicate itself to be fullfilled.
            #
            # @example ignore all errors originating from this event emission
            #    ignore_errors_from emit(task.stop_event)
            def ignore_errors_from(expectations, backtrace: caller(1))
                expectations = Array(expectations)
                expectations.each do |e|
                    @expectations.delete(e)
                end
                add_expectation(IgnoreErrorsFrom.new(expectations, backtrace))
            end

            # @!endgroup Expectations

            # Parse a expect { } block into an Expectation object
            #
            # @return [Expectation]
            def self.parse(test, plan, &block)
                new(test, plan).parse(&block)
            end

            def parse(ret: true, &block)
                block_ret = instance_eval(&block)
                @return_objects = block_ret if ret
                self
            end

            def initialize(test, plan)
                @test = test
                @plan = plan

                @expectations = []
                @execute_blocks = []
                @poll_blocks = []

                @scheduler = false
                @timeout = 5
                @join_all_waiting_work = true
                @wait_until_timeout = true
                @garbage_collect = false
                @validate_unexpected_errors = true
                @display_exceptions = false
                @filter_out_related_errors = true
            end

            def find_tasks(*args)
                @test.plan.find_tasks(*args)
            end

            def respond_to_missing?(m, include_private)
                @test.respond_to?(m) || super
            end

            def method_missing(m, *args, &block)
                if @test.respond_to?(m)
                    @test.public_send(m, *args, &block)
                else
                    super
                end
            end

            def self.format_propagation_info(propagation_info, indent: 0)
                PP.pp(propagation_info, "".dup).split("\n").join("\n#{' ' * indent}")
            end

            class Unmet < Minitest::Assertion
                def initialize(expectations_with_explanations, propagation_info)
                    super()

                    @expectations = expectations_with_explanations
                    @propagation_info = propagation_info
                end

                def each_original_exception
                    return enum_for(__method__) unless block_given?

                    @expectations.each do |(_, e)|
                        yield(e) if e.kind_of?(Exception)
                    end
                end

                def pretty_print(pp)
                    pp.text "#{@expectations.size} unmet expectations"
                    @expectations.each do |exp, explanation|
                        pp.breakable
                        exp.pretty_print(pp)
                        if explanation
                            pp.text ", "
                            exp.format_unachievable_explanation(pp, explanation)
                        end
                    end

                    return if @propagation_info.empty?

                    pp.breakable
                    @propagation_info.pretty_print(pp)
                end

                def to_s
                    PP.pp(self, "".dup, 1).strip
                end
            end

            class UnexpectedErrors < Minitest::Assertion
                def initialize(errors)
                    super()

                    @errors = errors
                end

                def each_execution_exception
                    return enum_for(__method__) unless block_given?

                    @errors.each do |e|
                        yield(e) if e.kind_of?(ExecutionException)
                    end
                end

                def each_original_exception
                    return enum_for(__method__) unless block_given?

                    @errors.each do |e|
                        yield(e) if e.kind_of?(Exception)
                        yield(e.exception) if e.kind_of?(ExecutionException)
                    end
                end

                def droby_dump(peer)
                    UnexpectedErrors.new(
                        @errors.map { |e| peer.dump(e) }
                    )
                end

                def proxy(peer)
                    UnexpectedErrors.new(
                        @errors.map { |e| peer.local_object(e) }
                    )
                end

                def to_s
                    formatted_errors = @errors.each_with_index.map do |e, i|
                        formatted_execution_exception =
                            "[#{i + 1}/#{@errors.size}] " +
                            Roby.format_exception(e).join("\n")

                        e = e.exception if e.kind_of?(ExecutionException)
                        if e.backtrace && !e.backtrace.empty?
                            formatted_execution_exception +=
                                "\n    #{e.backtrace.join("\n    ")}"
                        end

                        sub_exceptions = Roby.flatten_exception(e)
                        sub_exceptions.delete(e)
                        formatted_sub_exceptions =
                            sub_exceptions.each_with_index.map do |sub_e, sub_i|
                                formatted = "[#{sub_i}] " +
                                            Roby.format_exception(sub_e).join("\n    ")
                                backtrace = Roby.format_backtrace(sub_e)
                                unless backtrace.empty?
                                    formatted += "    #{backtrace.join("\n    ")}"
                                end
                                formatted
                            end.join("\n  ")

                        unless formatted_sub_exceptions.empty?
                            formatted_execution_exception +=
                                "\n  #{formatted_sub_exceptions}"
                        end
                        formatted_execution_exception
                    end.join("\n")
                    "#{@errors.size} unexpected errors\n#{formatted_errors}"
                end
            end

            # @!group Setup

            # @!method timeout(timeout)
            #
            # How long will the test wait either for asynchronous jobs (if
            # #wait_until_timeout is false and #join_all_waiting_work is true)
            # or until it succeeds (if #wait_until_timeout is true)
            #
            # @param [Float] timeout
            #
            # The default is 5s
            dsl_attribute :timeout

            # @!method wait_until_timeout(wait)
            #
            # Whether the execution will run until the timeout if the
            # expectations have not been met yet.
            #
            # The default is true
            #
            # @param [Boolean] wait
            dsl_attribute :wait_until_timeout

            # @!method join_all_waiting_work(join)
            #
            # Whether the expectation test should wait for asynchronous work to
            # finish between event propagations
            #
            # The default is true
            #
            # @param [Boolean] join
            dsl_attribute :join_all_waiting_work

            # @!method scheduler(enabled_or_scheduler)
            #
            # Controls the scheduler
            #
            # The default is false
            #
            # @overload scheduler(enabled)
            #   @param [Boolean] enabled controls whether the scheduler is
            #     enabled or not
            #
            # @overload scheduler(scheduler)
            #   @param [Schedulers::Basic] the scheduler object that should be used
            dsl_attribute :scheduler

            # @!method garbage_collect(enable)
            #
            # Whether a garbage collection pass should be run
            #
            # The default is false
            #
            # @param [Boolean] enable
            dsl_attribute :garbage_collect

            # @!method filter_out_related_errors(enable)
            #
            # When enabled, errors that are caused by something that has a matcher
            # will not be reported as unexpected. For instance, a DependencyFailedError
            # caused by an event, when there is the corresponding `emit` predicate.
            #
            # The default is true
            #
            # @param [Boolean] enable
            dsl_attribute :filter_out_related_errors

            # @!method validate_unexpected_errors(enable)
            #
            # Whether the expectations will pass if exceptions are propagated
            # that are not explicitely expected
            #
            # The default is true
            #
            # @param [Boolean] enable
            dsl_attribute :validate_unexpected_errors

            # @!method display_exceptions(enable)
            #
            # Whether exceptions should be displayed by the execution engine
            #
            # The default is false
            #
            # @param [Boolean] enable
            dsl_attribute :display_exceptions

            # Setups a block that should be called at each execution cycle
            def poll(&block)
                @poll_blocks << block
                self
            end

            # @!endgroup Setup

            # Add a new expectation to be run during {#verify}
            def add_expectation(expectation)
                @expectations << expectation
                expectation
            end

            # Queue a block for execution
            #
            # This is meant to be used by expectation objects which require to
            # perform some actions in execution context.
            def execute(&block)
                @execute_blocks << block
                nil
            end

            # Whether some blocks have been queued for execution with
            # {#execute}
            def has_pending_execute_blocks? # rubocop:disable Naming/PredicateName
                !@execute_blocks.empty?
            end

            def with_execution_engine_setup
                engine = @plan.execution_engine
                current_scheduler = engine.scheduler
                current_scheduler_state = engine.scheduler.enabled?
                current_display_exceptions = engine.display_exceptions?
                unless display_exceptions.nil?
                    engine.display_exceptions = @display_exceptions
                end
                unless scheduler.nil?
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
            #
            # @return [Object] a value or array of value as returned by the
            #   parsed block. If the block returns expectations, they are
            #   converted to a user-visible object by calling their
            #   #return_object method. Each expectation documents this as their
            #   return value (for instance, {#achieve} returns the block's
            #   "trueish" value)
            def verify(&block)
                all_propagation_info = ExecutionEngine::PropagationInfo.new
                timeout_deadline = Time.now_without_mock_time + @timeout

                @execute_blocks << block if block

                engine = @plan.execution_engine
                loop do
                    engine.start_new_cycle
                    with_execution_engine_setup do
                        propagation_info = engine.process_events(
                            raise_framework_errors: false,
                            garbage_collect_pass: @garbage_collect
                        ) do
                            @execute_blocks.delete_if do |b|
                                b.call
                                true
                            end
                            @poll_blocks.each(&:call)

                            if engine.has_waiting_work?
                                engine.process_waiting_work
                                Thread.pass
                            end
                        end
                        all_propagation_info.merge(propagation_info)

                        exceptions = engine.cycle_end({}, raise_framework_errors: false)
                        all_propagation_info.framework_errors.concat(exceptions)
                    end

                    unmet = find_all_unmet_expectations(all_propagation_info)
                    unachievable = unmet.find_all do |expectation|
                        expectation.unachievable?(all_propagation_info)
                    end
                    unless unachievable.empty?
                        unachievable = unachievable.map do |expectation|
                            explanation = expectation
                                          .explain_unachievable(all_propagation_info)
                            [expectation, explanation]
                        end
                        raise Unmet.new(unachievable, all_propagation_info)
                    end

                    if @validate_unexpected_errors
                        validate_has_no_unexpected_error(all_propagation_info)
                    end

                    remaining_timeout = timeout_deadline - Time.now_without_mock_time
                    break if remaining_timeout < 0

                    if @join_all_waiting_work && engine.has_waiting_work?
                        next
                    elsif has_pending_execute_blocks?
                        next
                    elsif unmet.empty?
                        break
                    elsif !@wait_until_timeout
                        break
                    end
                end

                if @join_all_waiting_work && engine.has_waiting_work?
                    e = ExecutionEngine::JoinAllWaitingWorkTimeout.new(
                        engine.waiting_work
                    )
                    raise UnexpectedErrors.new([e]),
                          "some asynchronous work did not finish"
                end

                unmet = find_all_unmet_expectations(all_propagation_info)
                raise Unmet.new(unmet, all_propagation_info) unless unmet.empty?

                if @validate_unexpected_errors
                    validate_has_no_unexpected_error(all_propagation_info)
                end

                if @return_objects.respond_to?(:to_ary)
                    compute_returned_objects(@return_objects)
                else
                    compute_returned_objects([@return_objects]).first
                end
            end

            # Process the value returned by the `.to { }` block to convert it to
            # the actual result of the expectations
            def compute_returned_objects(return_objects)
                return_objects.map do |ret|
                    obj = ret.respond_to?(:return_object) ? ret.return_object : ret
                    obj = ret.filter_result(obj) if ret.respond_to?(:filter_result)
                    obj
                end
            end

            def validate_has_no_unexpected_error(propagation_info)
                unexpected_errors = propagation_info.exceptions.find_all do |e|
                    unexpected_error?(e)
                end
                unexpected_errors.concat(
                    propagation_info.each_framework_error
                                    .map(&:first)
                                    .find_all { |e| unexpected_error?(e) }
                )

                # Look for internal_error_event, which is how the tasks report
                # on their internal errors
                internal_errors = propagation_info.emitted_events.find_all do |ev|
                    is_internal_error =
                        ev.generator.respond_to?(:symbol) &&
                        ev.generator.symbol == :internal_error
                    next unless is_internal_error

                    ev.context.any? do |obj|
                        unexpected_error?(obj) if obj.kind_of?(Exception)
                    end
                end

                unexpected_errors += internal_errors.flat_map(&:context)
                return if unexpected_errors.empty?

                raise UnexpectedErrors.new(unexpected_errors)
            end

            # Checks whether the given error is unexpected, given the predicates
            #
            # It filters out errors that are related to certain predicates, as
            # tested with the {Expectation#relates_to_error?} test
            #
            # @param [ExecutionException,Exception] error
            def unexpected_error?(error)
                return true unless @filter_out_related_errors

                all_errors = Roby.flatten_exception(error)
                has_related_predicate = @expectations.any? do |expectation|
                    all_errors.any? { |orig_e| expectation.relates_to_error?(orig_e) }
                end
                !has_related_predicate
            end

            def find_all_unmet_expectations(all_propagation_info)
                @expectations.find_all do |exp|
                    !exp.update_match(all_propagation_info)
                end
            end

            # @api private
            # Null implementation of an expectation
            class Expectation
                attr_reader :backtrace

                def initialize(backtrace)
                    @backtrace = backtrace
                    @result_filters = []
                end

                # Verifies whether the expectation is met at this point
                #
                # This method is meant to update
                def update_match(_propagation_info)
                    true
                end

                def unachievable?(_propagation_info)
                    false
                end

                def explain_unachievable(_propagation_info)
                    nil
                end

                def relates_to_error?(_error)
                    false
                end

                def format_unachievable_explanation(pp, explanation)
                    pp.text "but it did not because of "
                    case explanation
                    when Exception
                        msg = Roby.format_exception(explanation, with_backtrace: true)
                        msg.each do |line|
                            pp.text line
                            pp.breakable
                        end
                    when Event
                        explanation.pretty_print(pp)
                        if (e = explanation.context.first).kind_of?(Exception)
                            msg = Roby.format_exception(e, with_backtrace: true)
                            pp.nest(2) do
                                msg.each do |line|
                                    pp.breakable
                                    pp.text line
                                end
                            end
                        end
                    else
                        explanation.pretty_print(pp)
                    end
                end

                # Add a block that should be used to filter the result of this
                # expectation before returning it to the caller
                #
                # This is meant to be used to re-use general expectations in more
                # specific ones
                def filter_result_with(&block)
                    @result_filters << block
                    self
                end

                # Filter the result of this expectation before returning it to the
                # user
                #
                # @see filter_result_with
                def filter_result(result)
                    @result_filters.inject(result) { |o, b| b.call(o) }
                end
            end

            # Expectation wrapper that takes an expectation and ignores all
            # errors that are related to it
            class IgnoreErrorsFrom < Expectation
                def initialize(expectations, backtrace)
                    super(backtrace)
                    @expectations = Array(expectations)
                end

                def update_match(propagation_info)
                    # Call the underlying #update_match as some matchers cache
                    # information there
                    @expectations.each { |e| e.update_match(propagation_info) }
                    true
                end

                def relates_to_error?(error)
                    @expectations.any? do |e|
                        e.relates_to_error?(error)
                    end
                end

                def filter_result(_result)
                    nil
                end
            end

            class NotEmitGenerator < Expectation
                def initialize(generator, backtrace, within: 0.5)
                    super(backtrace)
                    @generator = generator
                    @emitted_events = []
                    @related_error_matcher =
                        Queries::LocalizedErrorMatcher
                        .new
                        .with_origin(@generator)
                        .to_execution_exception_matcher

                    @deadline = Time.now_without_mock_time + within
                end

                def to_s
                    "#{@generator} should not be emitted"
                end

                def update_match(propagation_info)
                    @emitted_events +=
                        propagation_info
                        .emitted_events
                        .find_all { |ev| ev.generator == @generator }

                    @emitted_events.empty? if Time.now_without_mock_time >= @deadline
                end

                def unachievable?(_propagation_info)
                    !@emitted_events.empty?
                end

                def explain_unachievable(_propagation_info)
                    @emitted_events.first
                end

                def relates_to_error?(error)
                    @related_error_matcher === error
                end

                def format_unachievable_explanation(pp, explanation)
                    pp.text "but it was: "
                    explanation.pretty_print(pp)
                end
            end

            class NotEmitGeneratorModel < Expectation
                attr_reader :generator_model

                def initialize(event_query, backtrace, within: 0.5)
                    super(backtrace)
                    @event_query = event_query
                    @generators = []
                    @related_error_matchers = []
                    @emitted_events = []
                    @deadline = Time.now_without_mock_time + within
                end

                def to_s
                    "no events matching #{@event_query} should be emitted"
                end

                def update_match(propagation_info)
                    @emitted_events +=
                        propagation_info
                        .emitted_events
                        .find_all do |ev|
                            next unless @event_query === ev.generator

                            @generators << ev.generator
                            @related_error_matchers <<
                                Queries::LocalizedErrorMatcher
                                .new
                                .with_origin(ev.generator)
                                .to_execution_exception_matcher
                        end

                    @emitted_events.empty? if Time.now_without_mock_time > @deadline
                end

                def unachievable?(_propagation_info)
                    !@emitted_events.empty?
                end

                def explain_unachievable(_propagation_info)
                    @emitted_events.first
                end

                def relates_to_error?(error)
                    @related_error_matchers.any? { |match| match === error }
                end

                def format_unachievable_explanation(pp, explanation)
                    pp.text "but one was: "
                    explanation.pretty_print(pp)
                end
            end

            class EmitGeneratorModel < Expectation
                attr_reader :generator_model

                def initialize(event_query, backtrace)
                    super(backtrace)
                    @event_query = event_query
                    @generators = []
                    @related_error_matchers = []
                    @emitted_events = []
                end

                def to_s
                    "at least one event matching #{@event_query} should be emitted"
                end

                def update_match(propagation_info)
                    @emitted_events =
                        propagation_info
                        .emitted_events
                        .find_all do |ev|
                            next unless @event_query === ev.generator

                            @generators << ev.generator
                            @related_error_matchers <<
                                Queries::LocalizedErrorMatcher
                                .new
                                .with_origin(ev.generator)
                                .emitted
                                .to_execution_exception_matcher
                        end
                    !@emitted_events.empty?
                end

                def return_object
                    @emitted_events
                end

                def relates_to_error?(error)
                    @related_error_matchers.any? { |match| match === error }
                end
            end

            class EmitGenerator < Expectation
                attr_reader :generator

                def initialize(generator, backtrace)
                    super(backtrace)
                    @generator = generator
                    @related_error_matcher =
                        Queries::LocalizedErrorMatcher
                        .new
                        .with_origin(@generator)
                        .emitted
                        .to_execution_exception_matcher
                end

                def to_s
                    "#{@generator} should be emitted"
                end

                def update_match(propagation_info)
                    @emitted_events =
                        propagation_info
                        .emitted_events
                        .find_all { |ev| ev.generator == @generator }
                    !@emitted_events.empty?
                end

                def return_object
                    @emitted_events.first
                end

                def unachievable?(_propagation_info)
                    @generator.unreachable?
                end

                def explain_unachievable(_propagation_info)
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
                    @matched_execution_exceptions = []
                    @matched_exceptions = []
                end

                def update_match(exceptions, emitted_events)
                    @matched_execution_exceptions =
                        exceptions
                        .find_all { |error| @matcher === error }
                    matched_exceptions =
                        @matched_execution_exceptions
                        .map(&:exception).to_set

                    emitted_events.each do |ev|
                        next unless ev.generator.respond_to?(:symbol) &&
                                    ev.generator.symbol == :internal_error

                        ev.context.each do |obj|
                            next unless obj.kind_of?(Exception)
                            next unless @matcher === ExecutionException.new(obj)

                            matched_exceptions << obj
                        end
                    end

                    @matched_exceptions = matched_exceptions.flat_map do |e|
                        Roby.flatten_exception(e).to_a
                    end.to_set
                    !@matched_exceptions.empty?
                end

                def relates_to_error?(error)
                    case error
                    when ExecutionException
                        @matched_execution_exceptions.include?(error)
                    else
                        @matched_exceptions.include?(error)
                    end
                end

                def return_object
                    @matched_execution_exceptions.first ||
                        @matched_exceptions.first
                end
            end

            class HaveErrorMatching < ErrorExpectation
                def update_match(propagation_info)
                    super(propagation_info.exceptions, propagation_info.emitted_events)
                end

                def to_s
                    "should have an error matching #{@matcher}"
                end
            end

            class HaveHandledErrorMatching < ErrorExpectation
                def update_match(propagation_info)
                    super(propagation_info.handled_errors.map(&:first),
                          propagation_info.emitted_events)
                end

                def to_s
                    "should have handled an error matching #{@matcher}"
                end
            end

            class Quarantine < Expectation
                def initialize(task, backtrace)
                    super(backtrace)
                    @task = task

                    @related_error_matcher =
                        QuarantinedTaskError
                            .match
                            .to_execution_exception_matcher
                end

                def update_match(_propagation_info)
                    @task.quarantined?
                end

                def relates_to_error?(error)
                    @related_error_matcher === error
                end

                def to_s
                    "#{@task} should be quarantined"
                end
            end

            class BecomeUnreachable < Expectation
                def initialize(generator, backtrace)
                    super(backtrace)
                    @generator = generator
                end

                def update_match(_propagation_info)
                    @generator.unreachable?
                end

                def return_object
                    @generator.unreachability_reason
                end

                def to_s
                    "#{@generator} should be unreachable"
                end
            end

            class NotBecomeUnreachable < Expectation
                def initialize(generator, backtrace)
                    super(backtrace)
                    @generator = generator
                end

                def update_match(_propagation_info)
                    !@generator.unreachable?
                end

                def unachievable?(_propagation_info)
                    @generator.unreachable?
                end

                def to_s
                    "#{@generator} should not be unreachable"
                end
            end

            class FailsToStart < Expectation
                def initialize(task, reason, backtrace)
                    super(backtrace)
                    @task = task
                    return unless reason.respond_to?(:to_execution_exception_matcher)

                    @reason = reason.to_execution_exception_matcher
                    @related_error_match = make_related_error_matcher(reason)
                end

                def make_related_error_matcher(reason)
                    LocalizedError.match
                                  .with_original_exception(reason)
                                  .to_execution_exception_matcher
                end

                def update_match(_propagation_info)
                    if !@task.failed_to_start?
                        false
                    elsif !@reason
                        true
                    else
                        @reason === @task.failure_reason
                    end
                end

                def unachievable?(_propagation_info)
                    return unless @reason && @task.failed_to_start?

                    !(@reason === @task.failure_reason)
                end

                def relates_to_error?(exception)
                    return unless @task.failed_to_start?

                    reason =
                        if @reason
                            @reason
                        elsif @task.failure_reason
                            Queries::ExecutionExceptionMatcher
                            .new
                            .with_exception(@task.failure_reason)
                        end

                    return unless reason

                    related_error_matcher =
                        @related_error_matcher ||
                        make_related_error_matcher(reason)

                    (reason === exception) || (related_error_matcher === exception)
                end

                def explain_unachievable(_propagation_info)
                    "#{@task.failure_reason} does not match #{@reason}"
                end

                def return_object
                    @task.failure_reason
                end

                def to_s
                    "#{@generator} should fail to start"
                end
            end

            class PromiseFinishes < Expectation
                def initialize(promise, backtrace)
                    super(backtrace)
                    @promise = promise
                end

                def update_match(_propagation_info)
                    @promise.complete?
                end

                def to_s
                    "#{@promise} should have finished"
                end
            end

            class HaveFrameworkError < Expectation
                def initialize(error_matcher, backtrace)
                    super(backtrace)
                    @error_matcher = error_matcher
                end

                def update_match(propagation_info)
                    @matched_exceptions =
                        propagation_info
                        .framework_errors.map(&:first)
                        .find_all { |e| @error_matcher === e }
                    !@matched_exceptions.empty?
                end

                def relates_to_error?(error)
                    @matched_exceptions.include?(error)
                end

                def to_s
                    "should have a framework error matching #{@error_matcher}"
                end
            end

            class Maintain < Expectation
                def initialize(at_least_during, block, description, backtrace)
                    super(backtrace)
                    @at_least_during = at_least_during
                    @description = description || @backtrace[0].to_s
                    @block = block
                    @deadline = Time.now_without_mock_time + at_least_during
                    @failed = false
                end

                def update_match(propagation_info)
                    if !@block.call(propagation_info)
                        @failed = true
                        false
                    elsif Time.now_without_mock_time > @deadline
                        true
                    end
                end

                def unachievable?(_propagation_info)
                    @failed
                end

                def explain_unachievable(_propagation_info)
                    "#{self} returned false"
                end

                def to_s
                    if @description.respond_to?(:call)
                        @description.call
                    else
                        @description
                    end
                end
            end

            class Achieve < Expectation
                def initialize(block, description, backtrace)
                    super(backtrace)
                    @description = description || @backtrace[0].to_s
                    @block = block
                end

                def update_match(propagation_info)
                    @achieved ||= @block.call(propagation_info)
                end

                def return_object
                    @achieved
                end

                def to_s
                    if @description.respond_to?(:call)
                        @description.call
                    else
                        @description
                    end
                end
            end

            class NotFinalize < Expectation
                def initialize(plan_object, backtrace)
                    super(backtrace)
                    @plan_object = plan_object
                end

                def update_match(_propagation_info)
                    @plan_object.plan
                end

                def to_s
                    "#{@plan_object} should not be finalized"
                end
            end

            class Finalize < Expectation
                def initialize(plan_object, backtrace)
                    super(backtrace)
                    @plan_object = plan_object
                end

                def update_match(_propagation_info)
                    !@plan_object.plan
                end

                def to_s
                    "#{@plan_object} should be finalized"
                end
            end
        end
    end
end
