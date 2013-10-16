$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::ExecutionException do
    include Roby::SelfTest

    def create_exception_from(object)
        Roby::ExecutionException.new(Roby::LocalizedError.new(object))
    end

    describe "#initialize" do
        it "can initialize from a task" do
            plan.add(task = Roby::Task.new)
            error = create_exception_from(task)
            assert_equal(task, error.task)
            assert_equal([task], error.trace)
            assert_equal(nil, error.generator)
        end

        it "can initialize from a task event" do
            plan.add(task = Roby::Task.new)
            error = create_exception_from(ev = task.start_event)
            assert_equal(task, error.task)
            assert_equal(ev, error.generator)
            assert_equal([task], error.trace)
        end
    end

    describe "#fork" do
        it "isolates the traces" do
            task, t1, t2, t3 = prepare_plan :add => 5
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
            task, t1, t2, t3 = prepare_plan :add => 5
            e = create_exception_from(task)
            s = e.fork
            e.trace << t1
            s.trace << t2
            e.merge(s)
            assert_equal task, e.origin
        end

        it "does not duplicate tasks" do
            task, t1, t2, t3 = prepare_plan :add => 5
            e = create_exception_from(task)
            s = e.fork

            e.trace << t1
            s.trace << t2
            e.merge(s)
            assert [task, t1, t2], e.trace
        end
    end

    it "should be droby-marshallable" do
        task = prepare_plan :add => 1
        verify_is_droby_marshallable_object(create_exception_from(task))
    end
end

