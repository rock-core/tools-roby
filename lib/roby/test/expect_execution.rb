module Roby
    module Test
        # Testclass-level implementation of the expect_execution feature
        #
        # The heavy-lifting is done in {ExecutionExpectations}. This is really
        # only the sugar-coating above the test framework itself.
        module ExpectExecution
            # The context object that allows the expect_execution { }.to { }
            # syntax
            Context = Struct.new :expectations, :block do
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
                    expectations.parse(&expectation_block)
                    expectations.verify(&block)
                rescue Minitest::Assertion => e
                    raise e, e.message, caller(2)
                end
            end

            # Declare expectations about the execution of a code block
            #
            # @example emit an event and validate that it is emitted
            #
            #    plan.add(task = MyTask.new)
            #    expect_execution { task.start }.
            #       to { emit task.start_event }
            def expect_execution(&block)
                expectations = ExecutionExpectations.new(self, plan)
                Context.new(expectations, block)
            end

            def execute(garbage_collect: false)
                result = nil
                expect_execution { result = yield }.with_setup { garbage_collect(garbage_collect) }.to { }
                result
            rescue Minitest::Assertion => e
                raise e, e.message, caller(2)
            end
        end
    end
end

