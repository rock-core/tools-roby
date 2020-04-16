# frozen_string_literal: true

require "roby/test/self"

class TC_EventConstraints_UnboundPredicate < Minitest::Test
    class TaskModel < Roby::Tasks::Simple
        event :first, controlable: true
        event :second, controlable: true
    end

    def assert_is_true(predicate, task)
        assert(predicate.evaluate(task))
        assert(predicate.explain_true(task))
        assert(!predicate.explain_false(task))
        assert(!predicate.explain_static(task))
    end

    def assert_is_false(predicate, task)
        assert(!predicate.evaluate(task))
        assert(!predicate.explain_true(task))
        assert(predicate.explain_false(task), "#{predicate} is false but has no explanation for it")
        assert(!predicate.explain_static(task))
    end

    def assert_is_static(value, predicate, task)
        if value
            assert(predicate.evaluate(task))
            assert(predicate.explain_true(task))
            assert(!predicate.explain_false(task), "#{predicate} is true but explain_false returned something")
        else
            assert(!predicate.evaluate(task))
            assert(!predicate.explain_true(task))
            assert(predicate.explain_false(task))
        end
        assert(predicate.explain_static(task))
    end

    def refute_static(predicate, task)
        assert(!predicate.static?(task), "#{predicate} is static but should not be")
        assert_nil predicate.explain_static(task)
    end

    def assert_static(value, predicate, events, task, actual_predicate = nil)
        assert(predicate.static?(task))
        assert_explained_by(value, predicate, events, (actual_predicate || predicate).explain_static(task))
    end

    def assert_explained_by(value, predicate, event, explanation)
        assert(explanation, "no explanation given")
        if value.nil? # MT 5.10 started warning that MT6 would require this. Thanks guys.
            assert_nil explanation.value
        else
            assert_equal(value, explanation.value)
        end
        assert_equal(predicate, explanation.predicate)

        elements = explanation.elements.dup
        if event.kind_of?(Hash)
            elements.each do |el|
                assert(expectation = event[el.predicate], "#{el} is not expected")
                assert_explained_by(expectation[0], el.predicate, expectation[1], el)
            end
        else
            unless event.respond_to?(:to_ary)
                event = [event]
            end
            assert_equal(event, explanation.elements)
        end
    end

    def test_single
        pred = :start.emitted?

        plan.add(task = TaskModel.new)
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, task.start_event, pred.explain_false(task))

        execute { task.start! }
        assert(pred.evaluate(task))
        assert_explained_by(true, pred, task.start_event.last, pred.explain_true(task))
    end

    def test_single_from_now
        task_m = Task.new_submodel { terminates }
        task_m.event :intermediate
        pred = :intermediate.emitted?.from_now
        plan.add(task = task_m.new)
        execute { task.start! }
        refute pred.evaluate(task)
        execute { task.intermediate_event.emit }
        assert pred.evaluate(task)
        refute :intermediate.emitted?.from_now.evaluate(task)
    end

    def test_single_static_if_emitted
        pred = :start.emitted?

        plan.add(task = TaskModel.new)
        assert(!pred.static?(task))
        assert_nil pred.explain_static(task)
        execute { task.start! }
        assert(pred.static?(task))
        assert_explained_by(true, pred, task.start_event.last, pred.explain_static(task))
    end

    def test_single_static_if_unreachable
        pred = :first.emitted?

        plan.add(task = TaskModel.new)
        execute { task.start! }
        assert(!pred.static?(task))
        assert_nil pred.explain_static(task)
        execute { task.stop! }
        assert(pred.static?(task))
        assert_explained_by(nil, pred, task.first_event, pred.explain_static(task))
        assert_equal task.terminal_event, task.first_event.unreachability_reason
    end

    def test_negate
        root_pred = :start.emitted?
        pred = root_pred.negate

        plan.add(task = TaskModel.new)
        assert(pred.evaluate(task))
        assert_explained_by(false, root_pred, task.start_event, pred.explain_true(task))

        execute { task.start! }
        assert(!pred.evaluate(task))
        assert_explained_by(true, root_pred, task.start_event.last, pred.explain_false(task))
    end

    def test_negate_static
        root_pred = :start.emitted?
        pred = root_pred.negate

        plan.add(task = TaskModel.new)
        assert(!pred.static?(task))
        assert_nil pred.explain_static(task)
        execute { task.start! }
        assert(pred.static?(task))
        assert_explained_by(true, root_pred, task.start_event.last,
                            pred.explain_static(task))

        execute { task.stop! }
    end

    def test_followed_by
        pred = :first.followed_by(:second)

        plan.add(task = TaskModel.new)
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, task.first_event, pred.explain_false(task))

        execute do
            task.start!
            task.first!
        end
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, pred, task.second_event, pred.explain_false(task))
        execute { task.second! }
        assert(pred.evaluate(task))
        assert_explained_by(true, pred, [task.first_event.last, task.second_event.last], pred.explain_true(task))
        execute { task.first! }
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, pred, task.second_event, pred.explain_false(task))

        plan.add(task = TaskModel.new)
        assert(!pred.evaluate(task))
        execute do
            task.start!
            task.first!
        end
        assert(!pred.evaluate(task), pred.code)
        execute { task.success! }
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, task.second_event, pred.explain_false(task))
    end

    def test_followed_by_static_at_false
        pred = :first.followed_by(:second)

        plan.add(task = TaskModel.new)
        refute_static(pred, task)
        execute { task.start! }
        refute_static(pred, task)
        execute { task.stop! }
        assert(!pred.evaluate(task))
        assert_static(nil, pred, [task.first_event], task)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.first!
        end
        refute_static(pred, task)
        execute { task.stop! }
        assert(!pred.evaluate(task))
        assert_static(nil, pred, [task.second_event], task)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.first!
            task.second!
        end
        refute_static(pred, task)
        execute { task.first! }
        refute_static(pred, task)
        execute { task.stop! }
        assert(!pred.evaluate(task))
        assert(pred.static?(task))
        assert_explained_by(nil, pred, [task.second_event],
                            pred.explain_static(task))
    end

    def test_followed_by_static_at_true
        pred = :first.followed_by(:second)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.first!
            task.second!
            task.stop!
        end
        assert(pred.static?(task))
        assert_explained_by(nil, pred, [task.first_event],
                            pred.explain_static(task))
    end

    def test_not_followed_by
        pred = :first.not_followed_by(:second)

        plan.add(task = TaskModel.new)
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, task.first_event, pred.explain_false(task))

        execute do
            task.start!
            task.first!
        end
        assert(pred.evaluate(task), pred.code)
        assert_explained_by(true, pred, [task.first_event.last, task.second_event], pred.explain_true(task))

        execute { task.second! }
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, pred, task.second_event.last, pred.explain_false(task))

        execute { task.first! }
        assert(pred.evaluate(task), pred.code)
        assert_explained_by(true, pred, [task.first_event.last, task.second_event.last], pred.explain_true(task))

        plan.add(task = TaskModel.new)
        assert(!pred.evaluate(task))
        execute do
            task.start!
            task.first!
        end
        assert(pred.evaluate(task), pred.code)
        execute { task.stop! }
        assert(pred.evaluate(task))
    end

    def test_not_followed_by_static_at_false
        pred = :first.not_followed_by(:second)

        plan.add(task = TaskModel.new)
        refute_static(pred, task)

        execute do
            task.start!
            task.stop!
        end
        assert(!pred.evaluate(task))
        assert_static(nil, pred, task.first_event, task)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.first!
            task.second!
            task.stop!
        end
        assert(!pred.evaluate(task))
        assert_static(nil, pred, task.first_event, task)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.first!
        end
        refute_static(pred, task)
        execute { task.second! }
        refute_static(pred, task)
        execute { task.second_event.unreachable! }
        refute_static(pred, task)
        execute { task.first_event.unreachable! }
        assert(!pred.evaluate(task))
        assert_static(nil, pred, task.first_event, task)
    end

    def test_not_followed_by_static_at_true
        pred = :first.not_followed_by(:second)

        plan.add(task = TaskModel.new)
        refute_static(pred, task)

        execute do
            task.start!
            task.first!
            task.stop!
        end
        assert(pred.evaluate(task))
        assert_static(nil, pred, [task.first_event, task.second_event], task)
    end

    def test_and
        first_pred  = :start.followed_by(:failed)
        second_pred = :first.followed_by(:second)
        pred = first_pred.and(second_pred)

        plan.add(task = TaskModel.new)
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred,
                            Hash[first_pred => [false, task.start_event],
                                 second_pred => [false, task.first_event]],
                            pred.explain_false(task))

        execute { task.start! }
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, pred,
                            Hash[first_pred => [false, task.failed_event],
                                 second_pred => [false, task.first_event]],
                            pred.explain_false(task))

        execute { task.first! }
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, pred,
                            Hash[first_pred => [false, task.failed_event],
                                 second_pred => [false, task.second_event]],
                            pred.explain_false(task))

        execute { task.second! }
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, first_pred, task.failed_event, pred.explain_false(task))

        execute { task.stop! }
        assert(pred.evaluate(task))
        assert_explained_by(true, pred,
                            Hash[first_pred => [true, [task.start_event.last, task.failed_event.last]],
                                 second_pred => [true, [task.first_event.last, task.second_event.last]]],
                            pred.explain_true(task))

        # Make first_pred true but keep second_pred false
        plan.add(task = TaskModel.new)
        assert(!pred.evaluate(task))
        execute { task.start! }
        assert(!pred.evaluate(task), pred.code)
        execute { task.second! }
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, pred,
                            Hash[first_pred => [false, task.failed_event],
                                 second_pred => [false, task.first_event]],
                            pred.explain_false(task))

        execute { task.first! }
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, pred,
                            Hash[first_pred => [false, task.failed_event],
                                 second_pred => [false, task.second_event]],
                            pred.explain_false(task))

        execute { task.stop! }
        assert(!pred.evaluate(task))
        assert_explained_by(false, second_pred, task.second_event, pred.explain_false(task))

        # Make second_pred true but keep first_pred false
        plan.add(task = TaskModel.new)
        assert(!pred.evaluate(task))
        execute { task.start! }
        assert(!pred.evaluate(task), pred.code)
        execute { task.first! }
        assert(!pred.evaluate(task), pred.code)
        execute { task.second! }
        assert(!pred.evaluate(task), pred.code)
        execute { task.success! }
        assert(!pred.evaluate(task))
        assert_explained_by(false, first_pred, task.failed_event, pred.explain_false(task))
    end

    def test_and_static_at_false
        first_pred  = :start.followed_by(:failed)
        second_pred = :first.followed_by(:second)
        pred = first_pred.and(second_pred)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.stop!
        end
        assert(!pred.evaluate(task))
        assert_static(nil, pred,
                      Hash[first_pred => [nil, task.start_event],
                           second_pred => [nil, task.first_event]],
                      task)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.first!
            task.stop!
        end
        assert(first_pred.evaluate(task))
        assert(!pred.evaluate(task))
        assert(first_pred.static?(task))
        assert(second_pred.static?(task))
        assert_static(nil, pred,
                      Hash[first_pred => [nil, [task.start_event]],
                           second_pred => [nil, [task.second_event]]],
                      task)
    end

    def test_and_static_at_true
        first_pred  = :start.followed_by(:failed)
        second_pred = :first.followed_by(:second)
        pred = first_pred.and(second_pred)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.first!
            task.second!
            task.stop!
        end
        assert(pred.evaluate(task))
        assert_static(nil, pred,
                      Hash[first_pred => [nil, [task.start_event]],
                           second_pred => [nil, [task.first_event]]],
                      task)
    end

    def test_and_is_static_if_one_of_the_two_predicates_is_false_and_static
        first_pred  = :first.to_unbound_task_predicate
        second_pred = :second.to_unbound_task_predicate
        pred = first_pred.and(second_pred)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.first_event.unreachable!
        end
        assert pred.static?(task)
        assert_static(nil, first_pred, task.first_event, task, pred)
    end

    def test_or
        first_pred  = :start.followed_by(:failed)
        second_pred = :first.not_followed_by(:second)
        pred = first_pred.or(second_pred)

        # Make only first predicate true
        plan.add(task = TaskModel.new)
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, Hash[first_pred => [false, task.start_event], second_pred => [false, task.first_event]], pred.explain_false(task))

        execute { task.start! }
        assert(!pred.evaluate(task), pred.code)
        assert_explained_by(false, pred, Hash[first_pred => [false, task.failed_event], second_pred => [false, task.first_event]], pred.explain_false(task))

        execute { task.stop! }
        assert(pred.evaluate(task))
        assert_explained_by(true, first_pred, [task.start_event.last, task.failed_event.last], pred.explain_true(task))

        plan.add(task = TaskModel.new)
        assert(!pred.evaluate(task))

        execute { task.start! }
        assert(!pred.evaluate(task), pred.code)

        execute { task.first! }
        assert(pred.evaluate(task))
        assert_explained_by(true, second_pred, [task.first_event.last, task.second_event], pred.explain_true(task))

        execute { task.second! }
        assert(!pred.evaluate(task))
        assert_explained_by(false, pred, Hash[first_pred => [false, task.failed_event], second_pred => [false, task.second_event.last]], pred.explain_false(task))

        execute { task.stop! }
        assert_explained_by(true, first_pred, [task.start_event.last, task.failed_event.last], pred.explain_true(task))
    end

    def test_or_is_static_if_one_of_the_two_predicates_is_true_and_static
        first_pred  = :first.to_unbound_task_predicate
        second_pred = :second.to_unbound_task_predicate
        pred = first_pred.or(second_pred)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.first_event.emit
        end
        execute { task.first_event.unreachable! }
        assert pred.static?(task)
        assert_static(true, first_pred, task.first_event.last, task, pred)
    end

    def test_or_static_at_false
        first_pred  = :start.followed_by(:failed)
        second_pred = :first.not_followed_by(:second)
        pred = first_pred.or(second_pred)

        plan.add(task = TaskModel.new)
        execute do
            task.start!
            task.success!
        end
        assert(!pred.evaluate(task))
        assert_static(nil, pred,
                      Hash[first_pred => [nil, [task.failed_event]],
                           second_pred => [nil, [task.first_event]]],
                      task)
    end

    def test_and_atomic_predicates
        assert_equal [:start.to_unbound_task_predicate, :stop.to_unbound_task_predicate],
                     :start.and(:stop).enum_for(:each_atomic_predicate).to_a
        assert :start.and(:stop).has_atomic_predicate?(:start)
        assert :start.and(:stop).has_atomic_predicate?(:stop)
    end

    def test_and_reduction
        assert_equal :start.and(:stop), :start.and(:stop).and(:start).and(:stop)
    end

    def test_or_reduction
        assert_equal :start.or(:stop), :start.or(:stop).or(:start).or(:stop)
    end

    def test_never
        pred = :first.never

        plan.add(task = TaskModel.new)
        execute { task.start! }
        assert_is_false(pred, task)
        execute { task.stop! }
        assert_is_static(true, pred, task)

        plan.add(task = TaskModel.new)
        execute { task.failed_to_start!("test") }
        assert_is_static(true, pred, task)

        plan.add(task = TaskModel.new)
        execute { task.start! }
        execute { task.first! }
        assert_is_static(false, pred, task)
    end
end
