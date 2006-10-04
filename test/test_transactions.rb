require 'roby/transactions'
require 'test_plan.rb'
require 'flexmock'

# Check that a transaction behaves like a plan
class TC_TransactionAsPlan < Test::Unit::TestCase
    include TC_PlanStatic

    def setup
	@real_plan = Plan.new
	@plan = Transaction.new(@real_plan)
    end
    def teardown
	@plan.commit_transaction
	@real_plan.clear
    end
end


class TC_Transactions < Test::Unit::TestCase
    include Roby::Transactions
    Hierarchy = Roby::TaskStructure::Hierarchy
    PlannedBy = Roby::TaskStructure::PlannedBy
    Signal = Roby::EventStructure::Signal

    attr_reader :plan
    def setup
	@plan = Roby::Plan.new
    end
    def teardown
	plan.clear
    end

    def transaction_commit(plan)
	trsc = Roby::Transaction.new(plan)
	yield(trsc)
	trsc.commit_transaction

	# Check that there is no proxy left in the graph
	[[Roby::TaskStructure, Roby::Task], [Roby::EventStructure, Roby::EventGenerator]].each do |structure, klass|
	    structure.each_relation do |rel|
		rel.each_vertex do |v|
		    assert_kind_of(klass, v)
		end
	    end
	end
    end

    # Tests insertion and removal of tasks
    def test_commit_tasks
	t1, t2, t3 = (1..3).map { Roby::Task.new }
	plan.insert(t1)

	transaction_commit(plan) do |trsc|
	    assert(trsc.include?(t1))
	    assert(trsc.mission?(t1))
	    assert(trsc.include?(trsc[t1]))
	    assert(trsc.mission?(trsc[t1]))
	end

	transaction_commit(plan) do |trsc| 
	    trsc.discover(t3)
	    assert(trsc.include?(t3))
	    assert(!trsc.mission?(t3))
	    assert(!plan.include?(t3))
	    assert(!plan.mission?(t3))
	end
	assert(plan.include?(t3))
	assert(!plan.mission?(t3))

	transaction_commit(plan) do |trsc| 
	    trsc.insert(t2) 
	    assert(trsc.include?(t2))
	    assert(trsc.mission?(t2))
	    assert(!plan.include?(t2))
	    assert(!plan.mission?(t2))
	end
	assert(plan.include?(t2))
	assert(plan.mission?(t2))

	transaction_commit(plan) do |trsc|
	    trsc.discard(t2)
	    assert(trsc.include?(t2))
	    assert(!trsc.mission?(t2))
	    assert(plan.include?(t2))
	    assert(plan.mission?(t2))
	end
	assert(plan.include?(t2))
	assert(!plan.mission?(t2))

	transaction_commit(plan) do |trsc|
	    trsc.remove_task(trsc[t3]) 
	    assert(!trsc.include?(t3))
	    assert(plan.include?(t3))
	end
	assert(!plan.include?(t3))
	assert(!plan.mission?(t3))
    end

    def test_discover
	t1, t2, t3, t4 = (1..4).map { Roby::Task.new }
	plan.insert [t1, t2]
	t1.realized_by t2

	transaction_commit(plan) do |trsc|
	    trsc[t2].planned_by t3
	    t4.realized_by trsc[t1]
	end
    end

    def test_commit_task_relations
	t1, t2 = (1..2).map { Roby::Task.new }
	plan.insert [t1, t2]
	t1.realized_by t2

	t3, t4 = (1..2).map { Roby::Task.new }
	transaction_commit(plan) do |trsc|
	    trsc.discover t3
	    trsc.discover t4
	    t3.planned_by t4
	end
	assert(PlannedBy.linked?(t3, t4))

	t = Roby::Task.new
	transaction_commit(plan) do |trsc|
	    p1, p2 = trsc[t1], trsc[t2]
	    t.realized_by p1
	    assert(Hierarchy.linked?(t, p1))
	    assert(!Hierarchy.linked?(t, t1))
	end
	assert(Hierarchy.linked?(t, t1))

	t = Roby::Task.new
	transaction_commit(plan) do |trsc|
	    p1, p2 = trsc[t1], trsc[t2]
	    p2.realized_by t
	    assert(Hierarchy.linked?(p2, t))
	    assert(!Hierarchy.linked?(t2, t))
	end
	assert(Hierarchy.linked?(t2, t))

	transaction_commit(plan) do |trsc|
	    p1, p2 = trsc[t1], trsc[t2]
	    p1.remove_child_object(p2, Hierarchy)
	    assert(!Hierarchy.linked?(p1, p2))
	    assert(Hierarchy.linked?(t1, t2))
	end
	assert(!Hierarchy.linked?(t1, t2))

	transaction_commit(plan) do |trsc|
	    p3, p4 = trsc[t3], trsc[t4]
	    trsc.remove_task(p3)
	    assert(!trsc.include?(p3))
	    assert(!PlannedBy.linked?(p3, p4))
	    assert(PlannedBy.linked?(t3, t4))
	end
	assert(!PlannedBy.linked?(t3, t4))
    end

    def test_commit_event_relations
	t1, t2, t3, t4 = (1..4).map do 
	    Class.new(Roby::Task) do
		event(:start, :command => true)
		event(:stop, :command => true)
	    end.new
	end
	plan.insert [t1, t2]
	t1.on(:start, t2, :stop)

	transaction_commit(plan) do |trsc|
	    p1, p2 = trsc[t1], trsc[t2]
	    plan.discover t3
	    t3.event(:stop).on p2.event(:start)
	    assert(Signal.linked?(t3.event(:stop), p2.event(:start)))
	    assert(!Signal.linked?(t3.event(:stop), t2.event(:start)))
	end
	assert(Signal.linked?(t3.event(:stop), t2.event(:start)))

	transaction_commit(plan) do |trsc|
	    p1, p2 = trsc[t1], trsc[t2]
	    p1.event(:stop).on p2.event(:start)
	    assert(Signal.linked?(p1.event(:stop), p2.event(:start)))
	    assert(!Signal.linked?(t1.event(:stop), t2.event(:start)))
	end
	assert(Signal.linked?(t1.event(:stop), t2.event(:start)))

	transaction_commit(plan) do |trsc|
	    p1, p2 = trsc[t1], trsc[t2]
	    plan.discover t4
	    p1.event(:stop).on t4.event(:start)
	    assert(Signal.linked?(p1.event(:stop), t4.event(:start)))
	end
	assert(Signal.linked?(t1.event(:stop), t4.event(:start)))

	transaction_commit(plan) do |trsc|
	    p1, p2 = trsc[t1], trsc[t2]
	    p1.event(:start).remove_child_object(p2.event(:stop), Signal)
	    assert(!Signal.linked?(p1.event(:start), p2.event(:stop)))
	    assert(Signal.linked?(t1.event(:start), t2.event(:stop)))
	end
	assert(!Signal.linked?(t1.event(:start), t2.event(:stop)))
    end
    
    def test_commit_event_handlers
	e = Roby::EventGenerator.new(true)
	def e.called_by_handler(mock)
	    mock.called_by_handler
	end

	FlexMock.use do |mock|
	    transaction_commit(plan) do |trsc|
		pe = trsc[e]

		pe.on { mock.handler_called }
		pe.on { pe.called_by_handler(mock) }
	    end

	    mock.should_receive(:handler_called).once
	    mock.should_receive(:called_by_handler).once
	    e.call(nil)
	end
    end
end

