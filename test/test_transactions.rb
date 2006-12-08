require 'test_config'
require 'mockups/tasks'
require 'flexmock'

require 'test_plan'
require 'roby/transactions'

# Check that a transaction behaves like a plan
class TC_TransactionAsPlan < Test::Unit::TestCase
    include TC_PlanStatic
    include RobyTestCommon

    def setup
	@real_plan = Plan.new
	@plan = Transaction.new(@real_plan)
	super
    end
    def teardown
	@plan.discard_transaction
	@real_plan.clear
	super
    end
end

module TC_TransactionBehaviour
    include Roby::Transactions

    Hierarchy = Roby::TaskStructure::Hierarchy
    PlannedBy = Roby::TaskStructure::PlannedBy
    Signal = Roby::EventStructure::Signal

    def transaction_commit(plan, *needed_proxies)
	trsc = Roby::Transaction.new(plan)
	proxies = needed_proxies.map do |o|
	    plan.discover(o) unless o.plan

	    p = trsc[o]
	    assert_not_same(p, o)
	    p
	end
	yield(trsc, *proxies)

	# Check that no task in trsc are in plan, and that no task of plan are in trsc
	assert( (trsc.known_tasks & plan.known_tasks).empty?, (trsc.known_tasks & plan.known_tasks))

	trsc.commit_transaction

	# Check that there is no proxy left in the graph
	[[Roby::TaskStructure, Roby::Task], [Roby::EventStructure, Roby::EventGenerator]].each do |structure, klass|
	    structure.each_relation do |rel|
		rel.each_vertex do |v|
		    assert_kind_of(klass, v)
		end
	    end
	end
	plan.known_tasks.each do |t|
	    assert_kind_of(Roby::Task, t, t.class.ancestors.inspect)
	end
    end

    # Tests insertion and removal of tasks
    def test_commit_tasks
	t1, t2, t3 = (1..3).map { Roby::Task.new }
	plan.insert(t1)

	transaction_commit(plan, t1) do |trsc, p1|
	    assert(trsc.include?(t1))
	    assert(trsc.mission?(t1))
	    assert(trsc.include?(p1))
	    assert(trsc.mission?(p1))
	end

	transaction_commit(plan) do |trsc| 
	    assert(!trsc.include?(t3))
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
	    assert(trsc.include?(t2))
	    trsc.discard(t2)
	    assert(trsc.include?(t2))
	    assert(!trsc.mission?(t2))
	    assert(plan.include?(t2))
	    assert(plan.mission?(t2))
	end
	assert(plan.include?(t2))
	assert(!plan.mission?(t2))

	transaction_commit(plan, t3) do |trsc, p3|
	    trsc.remove_task(p3) 
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

	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    p2.planned_by t3
	    t4.realized_by p1

	    assert(trsc.discovered_relations_of?(p1))
	    assert(trsc.discovered_relations_of?(p2))
	    assert(trsc.discovered_relations_of?(t3))
	    assert(trsc.discovered_relations_of?(t4))
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
	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    t.realized_by p1
	    assert(Hierarchy.linked?(t, p1))
	    assert(!Hierarchy.linked?(t, t1))
	end
	assert(Hierarchy.linked?(t, t1))

	t = Roby::Task.new
	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    p2.realized_by t
	    assert(Hierarchy.linked?(p2, t))
	    assert(!Hierarchy.linked?(t2, t))
	end
	assert(Hierarchy.linked?(t2, t))

	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    p1.remove_child_object(p2, Hierarchy)
	    assert(!Hierarchy.linked?(p1, p2))
	    assert(Hierarchy.linked?(t1, t2))
	end
	assert(!Hierarchy.linked?(t1, t2))

	transaction_commit(plan, t3, t4) do |trsc, p3, p4|
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

	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    trsc.discover t3
	    t3.event(:stop).on p2.event(:start)
	    assert(Signal.linked?(t3.event(:stop), p2.event(:start)))
	    assert(!Signal.linked?(t3.event(:stop), t2.event(:start)))
	end
	assert(Signal.linked?(t3.event(:stop), t2.event(:start)))

	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    p1.event(:stop).on p2.event(:start)
	    assert(Signal.linked?(p1.event(:stop), p2.event(:start)))
	    assert(!Signal.linked?(t1.event(:stop), t2.event(:start)))
	end
	assert(Signal.linked?(t1.event(:stop), t2.event(:start)))

	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    trsc.discover t4
	    p1.event(:stop).on t4.event(:start)
	    assert(Signal.linked?(p1.event(:stop), t4.event(:start)))
	end
	assert(Signal.linked?(t1.event(:stop), t4.event(:start)))

	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
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
	    transaction_commit(plan, e) do |trsc, pe|
		pe.on { mock.handler_called }
		pe.on { pe.called_by_handler(mock) }
	    end

	    mock.should_receive(:handler_called).once
	    mock.should_receive(:called_by_handler).once
	    e.call(nil)
	end
    end

    def test_commit_replace
	t1, t2 = Roby::Task.new, Roby::Task.new
	t1.realized_by t2
	t1.event(:stop).on t2.event(:start)

	r = Roby::Task.new
	plan.insert(t1)
	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    trsc.replace(p1, r)
	    assert(Hierarchy.linked?(r, p2))
	    assert(!Hierarchy.linked?(r, t2))
	    assert(Signal.linked?(r.event(:stop), p2.event(:start)))
	    assert(!Signal.linked?(r.event(:stop), t2.event(:start)))
	end
	assert(Hierarchy.linked?(r, t2))
	assert_equal([r], plan.missions.to_a)
	assert(Signal.linked?(r.event(:stop), t2.event(:start)))

	t1, t2 = Roby::Task.new, Roby::Task.new
	t1.realized_by t2
	t1.event(:stop).on t2.event(:start)

	r = Roby::Task.new
	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    trsc.replace(p2, r)
	    assert(Hierarchy.linked?(p1, r))
	    assert(!Hierarchy.linked?(t1, r))
	    assert(Signal.linked?(p1.event(:stop), r.event(:start)))
	    assert(!Signal.linked?(t1.event(:stop), r.event(:start)))
	end
	assert(Hierarchy.linked?(t1, r))
	assert(Signal.linked?(t1.event(:stop), r.event(:start)))
    end

    def test_relation_validation
	t1, t2 = (1..2).map { ExecutableTask.new }
	transaction_commit(plan, t1) do |trsc, p1|
	    trsc.insert(t2)
	    assert_equal(plan, t1.plan)
	    assert_equal(trsc, p1.plan)
	    assert_equal(trsc, t2.plan)
	    assert_raises(Roby::InvalidPlanOperation) { t1.realized_by t2 }
	    assert_equal(plan, t1.event(:start).plan)
	    assert_equal(trsc, p1.event(:start).plan)
	    assert_equal(trsc, t2.event(:start).plan)
	    assert_raises(Roby::InvalidPlanOperation) { t1.event(:start).on t2.event(:start) }
	end
    end

    def test_and_event_aggregator
	t1, t2, t3 = (1..3).map { ExecutableTask.new }
	transaction_commit(plan, t1) do |trsc, p1|
	    trsc.insert(t2)
	    trsc.insert(t3)
	    and_generator = (p1.event(:start) & t2.event(:start))
	    assert_equal(trsc, and_generator.plan)
	    and_generator.on t3.event(:start)
	end

	t1.start!
	assert(!t3.running?)
	t2.start!
	assert(t3.running?)
    end

    def test_or_event_aggregator
	t1, t2, t3 = (1..3).map { ExecutableTask.new }
	transaction_commit(plan, t1) do |trsc, p1|
	    trsc.insert(t2)
	    trsc.insert(t3)
	    (p1.event(:start) | t2.event(:start)).on t3.event(:start)
	end

	t1.start!
	assert(t3.running?)
	assert_nothing_raised { t2.start! }
    end
end

class TC_Transactions < Test::Unit::TestCase
    include TC_TransactionBehaviour
    include RobyTestCommon

    attr_reader :plan
    def setup
	@plan = Roby::Plan.new
	super
    end
    def teardown
	plan.clear
	super
    end
end

class TC_RecursiveTransaction < Test::Unit::TestCase
    include TC_TransactionBehaviour
    include RobyTestCommon

    attr_reader :plan
    def setup
	@real_plan = Roby::Plan.new
	@plan = Roby::Transaction.new(@real_plan)
	super
    end
    def teardown
	plan.discard_transaction
	@real_plan.clear
	super
    end
end

