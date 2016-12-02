require 'roby/test/self'

module Roby
    describe ExecutionException do
        def create_exception_from(object)
            Roby::ExecutionException.new(Roby::LocalizedError.new(object))
        end

        describe "#initialize" do
            it "can initialize from a task" do
                plan.add(task = Roby::Task.new)
                error = create_exception_from(task)
                assert_equal(task, error.task)
                assert_equal([task], error.trace)
                assert_nil error.generator
            end

            it "can initialize from a task event" do
                plan.add(task = Roby::Task.new)
                error = create_exception_from(ev = task.start_event)
                assert_equal(task, error.task)
                assert_equal(ev, error.generator)
                assert_equal([task], error.trace)
            end
        end

        describe "#originates_from" do
            it "returns true if given the exception's origin task" do
                e = flexmock(failed_task: Roby::Task.new, failed_generator: nil)
                ee = ExecutionException.new(e)
                assert ee.originates_from?(e.failed_task)
            end
            it "returns true if given the exception's origin task generator" do
                t = Roby::Task.new
                e = flexmock(failed_task: t, failed_generator: t.start_event)
                ee = ExecutionException.new(e)
                assert ee.originates_from?(e.failed_generator)
                assert ee.originates_from?(e.failed_task)
            end
            it "returns true if given the exception's origin free generator" do
                e = flexmock(failed_task: nil, failed_generator: flexmock)
                ee = ExecutionException.new(e)
                assert ee.originates_from?(e.failed_generator)
            end
            it "returns false if given another task than the exception's origin task" do
                e = flexmock(failed_task: Roby::Task.new, failed_generator: nil)
                ee = ExecutionException.new(e)
                refute ee.originates_from?(Roby::Task.new)
            end
            it "returns false if given another generator than the exception's origin task generator" do
                t = Roby::Task.new
                e = flexmock(failed_task: t, failed_generator: t.start_event)
                ee = ExecutionException.new(e)
                refute ee.originates_from?(t.failed_event)
            end
            it "returns false if given another generator than the exception's origin free generator" do
                e = flexmock(failed_task: nil, failed_generator: flexmock)
                ee = ExecutionException.new(e)
                refute ee.originates_from?(Roby::EventGenerator.new)
            end
        end

        describe "#fork" do
            it "isolates the traces" do
                task, t1, t2, t3 = prepare_plan add: 5
                e = create_exception_from(task)
                s = e.fork

                e.trace << t1
                s.trace << t2
                assert_equal([task, t1], e.trace)
                assert_equal([task, t2], s.trace)
            end
        end

        describe "#merge" do
            it "keeps the origin" do
                task, t1, t2, t3 = prepare_plan add: 5
                e = create_exception_from(task)
                s = e.fork
                e.trace << t1
                s.trace << t2
                e.merge(s)
                assert_equal task, e.origin
            end

            it "does not duplicate tasks" do
                task, t1, t2, t3 = prepare_plan add: 5
                e = create_exception_from(task)
                s = e.fork

                e.trace << t1
                s.trace << t2
                e.merge(s)
                assert [task, t1, t2], e.trace
            end
        end
    end
end

