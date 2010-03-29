$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/test/tasks/simple_task'

require 'roby'
require 'roby/temporal_logic'

class TC_TemporalLogic < Test::Unit::TestCase
    include Roby::Test
    include Roby::Test::Assertions

    def test_unbound_predicate_happened
        pred = :start.happened?

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(pred.evaluate(task))
    end

    def test_unbound_predicate_not_happened
        pred = :start.happened?.negate

        plan.add(task = SimpleTask.new)
        assert(pred.evaluate(task))
        task.start!
        assert(!pred.evaluate(task))
    end

    def test_unbound_predicate_followed_by
        pred = :start.followed_by(:failed)

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(!pred.evaluate(task), pred.code)
        task.stop!
        assert(pred.evaluate(task))

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(!pred.evaluate(task), pred.code)
        task.success!
        assert(!pred.evaluate(task))
    end

    def test_unbound_predicate_not_followed_by
        pred = :start.not_followed_by(:failed)

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(pred.evaluate(task), pred.code)
        task.stop!
        assert(!pred.evaluate(task))

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(pred.evaluate(task), pred.code)
        task.success!
        assert(pred.evaluate(task))
    end

    def test_unbound_predicate_and
        pred = :start.followed_by(:failed).
            and(:first.followed_by(:second))

        model = Class.new(SimpleTask) do
            event :first, :controlable => true
            event :second, :controlable => true
        end

        plan.add(task = model.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(!pred.evaluate(task), pred.code)
        task.first!
        assert(!pred.evaluate(task), pred.code)
        task.second!
        assert(!pred.evaluate(task), pred.code)
        task.stop!
        assert(pred.evaluate(task))

        plan.add(task = model.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(!pred.evaluate(task), pred.code)
        task.second!
        assert(!pred.evaluate(task), pred.code)
        task.first!
        assert(!pred.evaluate(task), pred.code)
        task.stop!
        assert(!pred.evaluate(task))

        plan.add(task = model.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(!pred.evaluate(task), pred.code)
        task.first!
        assert(!pred.evaluate(task), pred.code)
        task.second!
        assert(!pred.evaluate(task), pred.code)
        task.success!
        assert(!pred.evaluate(task))
    end

    def test_unbound_predicate_or
        pred = :start.followed_by(:success).
            or(:start.followed_by(:failed))

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(!pred.evaluate(task), pred.code)
        task.stop!
        assert(pred.evaluate(task))

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(!pred.evaluate(task), pred.code)
        task.success!
        assert(pred.evaluate(task))
    end
end
