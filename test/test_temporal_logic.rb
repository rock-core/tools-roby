$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'flexmock'
require 'roby/test/tasks/simple_task'

require 'roby'
require 'roby/temporal_logic'

class TC_TemporalLogic < Test::Unit::TestCase
    include Roby::Test
    include Roby::Test::Assertions

    def assert_explained_by(value, predicate, event, explanation)
        assert(explanation = explanation[predicate])
        assert_equal(value, explanation.value)
        assert_equal(predicate, explanation.predicate)

        if !event.respond_to?(:to_ary)
            event = [event]
        end
        assert_equal(event, explanation.events)
    end

    def test_unbound_predicate_happened
        pred = :start.happened?

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, task.start_event, pred.explain_false(task))

        task.start!
        assert(pred.evaluate(task))
        assert_explained_by(true, pred, task.start_event.last, pred.explain_true(task))
    end

    def test_unbound_predicate_negate
        root_pred = :start.happened?
        pred = root_pred.negate

        plan.add(task = SimpleTask.new)
        assert(pred.evaluate(task))
        assert_explained_by(false, root_pred, task.start_event, pred.explain_true(task))

        task.start!
        assert(!pred.evaluate(task))
        assert_explained_by(true, root_pred, task.start_event.last, pred.explain_false(task))
    end

    def test_unbound_predicate_followed_by
        pred = :start.followed_by(:failed)

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, task.start_event, pred.explain_false(task))

        task.start!
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, pred, task.failed_event, pred.explain_false(task))

        task.stop!
        assert(pred.evaluate(task))
        assert_explained_by(true, pred, [task.start_event.last, task.failed_event.last], pred.explain_true(task))

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(!pred.evaluate(task), pred.code)
        task.success!
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, task.failed_event, pred.explain_false(task))
    end

    def test_unbound_predicate_not_followed_by
        pred = :start.not_followed_by(:failed)

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, task.start_event, pred.explain_false(task))

        task.start!
        assert(pred.evaluate(task), pred.code)
        assert_explained_by(true, pred, task.start_event.last, pred.explain_true(task))

        task.stop!
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, task.failed_event.last, pred.explain_false(task))

        plan.add(task = SimpleTask.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(pred.evaluate(task), pred.code)
        task.success!
        assert(pred.evaluate(task))
    end

    def test_unbound_predicate_and
        first_pred  = :start.followed_by(:failed)
        second_pred = :first.followed_by(:second)
        pred = first_pred.and(second_pred)

        model = Class.new(SimpleTask) do
            event :first, :controlable => true
            event :second, :controlable => true
        end

        plan.add(task = model.new)
        assert(!pred.evaluate(task))
        assert_explained_by(false, first_pred,  task.start_event, pred.explain_false(task))
        assert_explained_by(false, second_pred, task.first_event, pred.explain_false(task))

        task.start!
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, first_pred,  task.failed_event, pred.explain_false(task))
        assert_explained_by(false, second_pred, task.first_event, pred.explain_false(task))

        task.first!
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, first_pred,  task.failed_event, pred.explain_false(task))
        assert_explained_by(false, second_pred, task.second_event, pred.explain_false(task))

        task.second!
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, first_pred,  task.failed_event, pred.explain_false(task))
        assert(!pred.explain_false(task).has_key?(second_pred))

        task.stop!
        assert(pred.evaluate(task))
        assert_explained_by(true, first_pred,  [task.start_event.last, task.failed_event.last], pred.explain_true(task))
        assert_explained_by(true, second_pred, [task.first_event.last, task.second_event.last], pred.explain_true(task))

        # Make first_pred true but keep second_pred false
        plan.add(task = model.new)
        assert(!pred.evaluate(task))
        task.start!
        assert(!pred.evaluate(task), pred.code)
        task.second!
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, first_pred,  task.failed_event, pred.explain_false(task))
        assert_explained_by(false, second_pred, task.first_event, pred.explain_false(task))

        task.first!
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, first_pred,  task.failed_event, pred.explain_false(task))
        assert_explained_by(false, second_pred, task.second_event, pred.explain_false(task))

        task.stop!
        assert(!pred.evaluate(task))
        assert_explained_by(false, second_pred, task.second_event, pred.explain_false(task))
        assert(!pred.explain_false(task).has_key?(first_pred))

        # Make second_pred true but keep first_pred false
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
        assert_explained_by(false, first_pred,  task.failed_event, pred.explain_false(task))
        assert(!pred.explain_false(task).has_key?(second_pred))
    end

    def test_unbound_predicate_or
        first_pred  = :start.followed_by(:failed)
        second_pred = :first.not_followed_by(:second)
        pred = first_pred.or(second_pred)

        model = Class.new(SimpleTask) do
            event :first, :controlable => true
            event :second, :controlable => true
        end

        # Make only first predicate true
        plan.add(task = model.new)
        assert(!pred.evaluate(task))
        assert_explained_by(false, first_pred,  task.start_event, pred.explain_false(task))
        assert_explained_by(false, second_pred, task.first_event, pred.explain_false(task))

        task.start!
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, first_pred,  task.failed_event, pred.explain_false(task))
        assert_explained_by(false, second_pred, task.first_event, pred.explain_false(task))

        task.stop!
        assert(pred.evaluate(task))
        assert_explained_by(true, first_pred,  [task.start_event.last, task.failed_event.last], pred.explain_true(task))
        assert(!pred.explain_true(task).has_key?(second_pred))



        plan.add(task = model.new)
        assert(!pred.evaluate(task))

        task.start!
        assert(!pred.evaluate(task), pred.code)

        task.first!
        assert(pred.evaluate(task))
        assert_explained_by(true, second_pred, [task.first_event.last, task.second_event], pred.explain_true(task))
        assert(!pred.explain_true(task).has_key?(first_pred))

        task.second!
        assert(!pred.evaluate(task))
        assert_explained_by(false, first_pred,  task.failed_event, pred.explain_false(task))
        assert_explained_by(false, second_pred, [task.second_event.last], pred.explain_false(task))

        task.stop!
        assert_explained_by(true, first_pred,  [task.start_event.last, task.failed_event.last], pred.explain_true(task))
        assert(!pred.explain_true(task).has_key?(second_pred))
    end
end

