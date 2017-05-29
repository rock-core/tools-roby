module Roby
    module Test
        # Testclass-level implementation of the expect_execution feature
        #
        # The heavy-lifting is done in {ExecutionExpectations}. This is really
        # only the sugar-coating above the test framework itself.
        module ExpectExecution
            # The context object that allows the expect_execution { }.to { }
            # syntax
            Context = Struct.new :test, :expectations, :block do
                def with_setup(&block)
                    expectations.instance_eval(&block)
                    self
                end

                def with_timeout(timeout)
                    expectations.timeout(timeout)
                    self
                end

                def with_scheduling
                    expectations.scheduler(true)
                    self
                end

                def to(&expectation_block)
                    test.setup_current_expect_execution(self)
                    expectations.parse(&expectation_block)
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

            # Declare expectations about the execution of a code block
            #
            # @example emit an event and validate that it is emitted
            #
            #    plan.add(task = MyTask.new)
            #    expect_execution { task.start }.
            #       to { emit task.start_event }
            #
            # @raise [InvalidContext] if expect_execution is used from within an
            #   expect_execution context, or within propagation context
            def expect_execution(&block)
                if execution_engine.in_propagation_context?
                    raise InvalidContext, "cannot recursively call #expect_execution"
                end
                expectations = ExecutionExpectations.new(self, plan)
                Context.new(self, expectations, block)
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
            def execute(garbage_collect: false)
                result = nil
                expect_execution { result = yield }.with_setup { garbage_collect(garbage_collect) }.to { }
                result
            rescue Minitest::Assertion => e
                raise e, e.message, caller(2)
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

