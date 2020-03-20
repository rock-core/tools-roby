module Roby
    module Test
        # Test related to execution in a Roby context
        #
        # This is the public interface of Roby's test swiss-army knife
        # {#expect_execution}
        #
        # The block given to {#expect_execution} will be executed in Roby's
        # event propagation context, and then some expectations can be matched
        # against the result using the .to call:
        #
        #    expect_execution { ...code to be executed... }
        #       .to { ... expectations ... }
        #
        # See the 'Expectations' section of {ExecutionExpectations} for an
        # exhaustive list of existing expectations. Additional setup
        # regarding the processing loop is documented in the Setup section
        # of the same page, and can be used like this:
        #
        #    expect_execution { ...code to be executed... }
        #       .timeout(10)
        #       .scheduler(true)
        #       .to { ... expectations ... }
        #
        # The execution expectation object is actually executed when one of
        # the to_run or to { } methods is called. The former runs the block
        # without any expectation (and therefore runs it only once, or until
        # all async work is finished). The latter defines expectations and
        # verifies them.
        #
        # @example emit an event and validate that it is emitted
        #    plan.add(task = MyTask.new)
        #    expect_execution { task.start! }
        #       .to { emit task.start_event }
        #
        # Note that the heavy-lifting is done in {ExecutionExpectations}. This
        # is really only the sugar-coating above the test harness itself.
        module ExpectExecution
            # The context object that allows the expect_execution { }.to { }
            # syntax
            Context = Struct.new :test, :expectations, :block do
                SETUP_METHODS = [
                    :timeout,
                    :wait_until_timeout,
                    :join_all_waiting_work,
                    :scheduler,
                    :garbage_collect,
                    :validate_unexpected_errors,
                    :display_exceptions,
                    :poll]

                def respond_to_missing?(m, include_private)
                    SETUP_METHODS.include?(m)
                end

                def method_missing(m, *args, &block)
                    expectations.public_send(m, *args, &block)
                    self
                end

                # Run the block without any expectations
                #
                # Expectations might be added dynamically by the block given to
                # expect_execution using {ExpectExecution#add_expectations}
                def to_run
                    to
                end

                # Declare the expectations and run
                def to(&expectation_block)
                    test.setup_current_expect_execution(self)
                    if expectation_block
                        expectations.parse(&expectation_block)
                    end
                    expectations.verify(&block)
                rescue Minitest::Assertion => e
                    raise e, e.message, caller(2)
                ensure
                    test.reset_current_expect_execution
                end
            end

            # Exception raised when one of the method is called in a context
            # that is not allowed
            class InvalidContext < RuntimeError; end

            attr_accessor :expect_execution_default_timeout

            # Declare expectations about the execution of a code block
            #
            # See the documentation of {ExpectExecution} for more details
            #
            # @raise [InvalidContext] if expect_execution is used from within an
            #   expect_execution context, or within propagation context
            def expect_execution(plan: self.plan, &block)
                if plan.execution_engine.in_propagation_context?
                    raise InvalidContext, "cannot recursively call #expect_execution"
                end

                expectations = ExecutionExpectations.new(self, plan)
                context = Context.new(self, expectations, block)
                if @expect_execution_default_timeout
                    context.timeout(@expect_execution_default_timeout)
                end
                context
            end

            # @api private
            #
            # Set the current expect_execution context. This is used to check
            # for recursive calls to {#expect_execution}
            def setup_current_expect_execution(context)
                if @current_expect_execution
                    raise InvalidContext, "cannot perform an expect_execution test within another one"
                end
                @current_expect_execution = context
            end

            # @api private
            #
            # Reset the current expect_execution block. This is used to check
            # for recursive calls to {#expect_execution}
            def reset_current_expect_execution
                @current_expect_execution = nil
            end

            # Execute a block within the event propagation context
            def execute(plan: self.plan, garbage_collect: false)
                result = nil
                expect_execution(plan: plan) { result = yield }.garbage_collect(garbage_collect).to_run
                result
            rescue Minitest::Assertion => e
                raise e, e.message, caller(2)
            end

            # Run exactly once cycle
            def execute_one_cycle(plan: self.plan, scheduler: false, garbage_collect: false)
                expect_execution(plan: plan).
                    join_all_waiting_work(false).
                    scheduler(scheduler).
                    garbage_collect(garbage_collect).
                    to_run
            end

            # Add an expectation from within an execute { } or expect_execution
            # { } block
            #
            # @raise [InvalidContext] if called outside of an
            #   {#expect_execution} context
            def add_expectations(&block)
                if !@current_expect_execution
                    raise InvalidContext, "#add_expectations not called within an expect_execution context"
                end
                @current_expect_execution.expectations.parse(ret: false, &block)
            end
        end
    end
end
