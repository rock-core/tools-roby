$LOAD_PATH.unshift File.expand_path('.', File.dirname(__FILE__))
$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/test/tasks/simple_task'
require 'flexmock'

require 'test_plan'

# Check that a transaction behaves like a plan
class TC_TransactionAsPlan < Test::Unit::TestCase
    include TC_PlanStatic
    include Roby::Test

    attr_reader :real_plan
    attr_reader :plan
    def engine; (real_plan || plan).engine end
    def setup
	super
        @real_plan = @plan
	@plan = Transaction.new(real_plan)
    end
    def teardown
	@plan.discard_transaction
	real_plan.clear
	super
    end
end

module TC_TransactionBehaviour
    include Roby::Transactions

    Hierarchy = Roby::TaskStructure::Hierarchy
    PlannedBy = Roby::TaskStructure::PlannedBy
    Signal = Roby::EventStructure::Signal
    Forwarding = Roby::EventStructure::Forwarding

    SimpleTask = Roby::Test::SimpleTask

    def transaction_op(plan, op, *needed_proxies)
	trsc = Roby::Transaction.new(plan)
	proxies = needed_proxies.map do |o|
	    plan.add(o) unless o.plan

	    p = trsc[o]
	    assert_not_equal(p, o)
	    p
	end
	yield(trsc, *proxies)

	# Check that no task in trsc are in plan, and that no task of plan are in trsc
	assert( (trsc.known_tasks & plan.known_tasks).empty?, (trsc.known_tasks & plan.known_tasks))

	plan = trsc.plan
	trsc.send(op)
	assert(!trsc.plan)
	assert(plan.transactions.empty?)

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

    rescue
	trsc.discard_transaction rescue nil
	raise
    end

    def transaction_commit(plan, *needed_proxies, &block)
	transaction_op(plan, :commit_transaction, *needed_proxies, &block)
    end
    def transaction_discard(plan, *needed_proxies, &block)
	transaction_op(plan, :discard_transaction, *needed_proxies, &block)
    end

    # Checks that model-level task relations are kept if a task is modified by a transaction
    def test_commit_task
	t = prepare_plan :tasks => 1
	transaction_commit(plan, t) do |trsc, p|
	    trsc.add(p)
	    assert(p.event(:start).child_object?(p.event(:updated_data), Roby::EventStructure::Precedence))
	    assert(p.event(:failed).child_object?(p.event(:stop), Roby::EventStructure::Forwarding))
	end
	assert(t.event(:start).child_object?(t.event(:updated_data), Roby::EventStructure::Precedence))
	assert(t.event(:failed).child_object?(t.event(:stop), Roby::EventStructure::Forwarding))

	t = prepare_plan :add => 1
	transaction_commit(plan, t) do |trsc, p|
	    trsc.add_mission(p)
	end
	assert(t.event(:start).child_object?(t.event(:updated_data), Roby::EventStructure::Precedence))
	assert(t.event(:failed).child_object?(t.event(:stop), Roby::EventStructure::Forwarding))
    end

    def test_commit_arguments
	(t1, t2), t = prepare_plan :add => 2, :tasks => 1
	t1.arguments[:first] = 10
	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    p1.arguments[:first] = 20
	    p1.arguments[:second] = p2
	    trsc.add(t)
	    t.arguments[:task] = p2
	end

	assert_equal(20, t1.arguments[:first])
	assert_equal(t2, t1.arguments[:second])
	assert_equal(t2, t.arguments[:task])

	transaction_discard(plan, t1, t2) do |trsc, p1, p2|
	    p1.arguments[:first] = 10
	    assert_equal(p2, p1.arguments[:second])
	end

	assert_equal(20, t1.arguments[:first])
	assert_equal(t2, t1.arguments[:second])
    end

    # Tests insertion and removal of tasks
    def test_commit_plan_tasks
	t1, (t2, t3) = prepare_plan(:missions => 1, :tasks => 2)

	transaction_commit(plan, t1) do |trsc, p1|
	    assert(trsc.include?(p1))
	    assert(trsc.mission?(p1))
	end

	transaction_commit(plan) do |trsc| 
	    assert(!trsc.include?(t3))
	    trsc.add(t3)
	    assert(trsc.include?(t3))
	    assert(!trsc.mission?(t3))
	    assert(!plan.include?(t3))
	    assert(!plan.mission?(t3))
	end
	assert(plan.include?(t3))
	assert(!plan.mission?(t3))

	transaction_commit(plan) do |trsc| 
	    assert(!trsc.include?(t2))
	    trsc.add_mission(t2) 
	    assert(trsc.include?(t2))
	    assert(trsc.mission?(t2))
	    assert(!plan.include?(t2))
	    assert(!plan.mission?(t2))
	end
	assert(plan.include?(t2))
	assert(plan.mission?(t2))

	transaction_commit(plan, t2) do |trsc, p2|
	    assert(trsc.mission?(p2))
	    trsc.unmark_mission(p2)
	    assert(trsc.include?(p2))
	    assert(!trsc.mission?(p2))
	    assert(plan.include?(t2))
	    assert(plan.mission?(t2))
	end
	assert(plan.include?(t2))
	assert(!plan.mission?(t2))

	transaction_commit(plan, t3) do |trsc, p3|
	    assert(trsc.include?(p3))
	    trsc.remove_object(p3) 
	    assert(!trsc.include?(p3))
	    assert(!trsc.wrap(t3, false))
	    assert(!trsc.include?(t3))
	    assert(plan.include?(t3))
	end
	assert(!plan.include?(t3))
	assert(!plan.mission?(t3))

	plan.add_permanent(t3 = Roby::Task.new)
	transaction_commit(plan, t3) do |trsc, p3|
	    assert(trsc.permanent?(p3))
	    trsc.unmark_permanent(t3)
	    assert(!trsc.permanent?(p3))
	    assert(plan.permanent?(t3))
	end
	assert(!plan.permanent?(t3))

	transaction_commit(plan, t3) do |trsc, p3|
	    trsc.add_permanent(p3)
	    assert(trsc.permanent?(p3))
	    assert(!plan.permanent?(t3))
	end
	assert(plan.permanent?(t3))
    end
    
    # Tests insertion and removal of free events
    def test_commit_plan_events
        e1, e2 = (1..2).map { Roby::EventGenerator.new }
        plan.add_permanent(e1)
        plan.add(e2)

	transaction_commit(plan, e1, e2) do |trsc, p1, p2|
	    assert(trsc.include?(p1))
	    assert(trsc.permanent?(p1))
	    assert(trsc.include?(p2))
	    assert(!trsc.permanent?(p2))

            trsc.unmark_permanent(p1)
	    assert(!trsc.permanent?(p1))
	end
        assert(!plan.permanent?(e1))

        e3, e4 = (1..2).map { Roby::EventGenerator.new }
	transaction_commit(plan) do |trsc|
            trsc.add_permanent(e3)
            trsc.add(e4)
	    assert(trsc.permanent?(e3))
	    assert(trsc.include?(e4))
	    assert(!trsc.permanent?(e4))
	end
        assert(plan.include?(e3))
        assert(plan.permanent?(e3))
        assert(plan.include?(e4))
        assert(!plan.permanent?(e4))
    end


    def test_commit_task_relations
	(t1, t2), (t3, t4) = prepare_plan(:missions => 2, :tasks => 2)
	t1.depends_on t2

	transaction_commit(plan) do |trsc|
	    trsc.add t3
	    trsc.add t4
	    t3.planned_by t4
	end
	assert(PlannedBy.linked?(t3, t4))

	t = Roby::Task.new
	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    t.depends_on p1
	    assert(Hierarchy.linked?(t, p1))
	    assert(!Hierarchy.linked?(t, t1))
	end
	assert(Hierarchy.linked?(t, t1))

	t = Roby::Task.new
	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    p2.depends_on t
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
	    trsc.remove_object(p3)
	    assert(!trsc.include?(p3))
	    assert(!PlannedBy.linked?(p3, p4))
	    assert(PlannedBy.linked?(t3, t4))
	end
	assert(!PlannedBy.linked?(t3, t4))
    end

    def test_commit_event_relations
	(t1, t2), (t3, t4) = prepare_plan :missions => 2, :tasks => 2,
	    :model => SimpleTask
	t1.signals(:start, t2, :success)

	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    trsc.add t3
            t3.signals(:stop, p2, :start)
	    assert(Signal.linked?(t3.event(:stop), p2.event(:start)))
	    assert(!Signal.linked?(t3.event(:stop), t2.event(:start)))
	end
	assert(Signal.linked?(t3.event(:stop), t2.event(:start)))

	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
            p1.signals(:stop, p2, :start)
	    assert(Signal.linked?(p1.event(:stop), p2.event(:start)))
	    assert(!Signal.linked?(t1.event(:stop), t2.event(:start)))
	end
	assert(Signal.linked?(t1.event(:stop), t2.event(:start)))

	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    trsc.add t4
	    p1.signals(:stop, t4, :start)
	    assert(Signal.linked?(p1.event(:stop), t4.event(:start)))
	end
	assert(Signal.linked?(t1.event(:stop), t4.event(:start)))

	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    p1.event(:start).remove_child_object(p2.event(:success), Signal)
	    assert(!Signal.linked?(p1.event(:start), p2.event(:success)))
	    assert(Signal.linked?(t1.event(:start), t2.event(:success)))
	end
	assert(!Signal.linked?(t1.event(:start), t2.event(:success)))
    end
    
    def test_commit_replace
	task, (planned, mission, child, r) = prepare_plan :missions => 1, :tasks => 4, :model => SimpleTask
	mission.depends_on task
	planned.planned_by task
	task.depends_on child
	task.signals(:stop, mission, :stop)
	task.forward_to(:stop, planned, :success)
	task.signals(:start, child, :start)

	transaction_commit(plan, mission, planned, task, child) do |trsc, pm, pp, pt, pc|
	    trsc.replace(pt, r)

	    assert([r], trsc.missions.to_a)
	    assert(Hierarchy.linked?(pm, r))
	    assert(!Hierarchy.linked?(mission, r))
	    assert(!Hierarchy.linked?(r, pc))
	    assert(PlannedBy.linked?(pp, r))
	    assert(!PlannedBy.linked?(planned, r))

	    assert(Signal.linked?(r.event(:stop), pm.event(:stop)))
	    assert(!Signal.linked?(r.event(:stop), mission.event(:stop)))
	    assert(Forwarding.linked?(r.event(:stop), pp.event(:success)))
	    assert(!Forwarding.linked?(r.event(:stop), planned.event(:success)))
	    assert(!Signal.linked?(r.event(:stop), pc.event(:stop)))
	    assert(!Signal.linked?(r.event(:stop), mission.event(:stop)))
	end
	assert(Hierarchy.linked?(mission, r))
	assert(!Hierarchy.linked?(mission, task))
	assert(PlannedBy.linked?(planned, r))
	assert(!PlannedBy.linked?(planned, task))
	assert(Hierarchy.linked?(task, child))
	assert(!Hierarchy.linked?(r, child))
	assert(Signal.linked?(r.event(:stop), mission.event(:stop)))
	assert(!Signal.linked?(task.event(:stop), mission.event(:stop)))
	assert(Forwarding.linked?(r.event(:stop), planned.event(:success)))
	assert(!Forwarding.linked?(task.event(:stop), planned.event(:success)))
	assert(Signal.linked?(task.event(:start), child.event(:start)))
	assert(!Signal.linked?(r.event(:start), child.event(:start)))
	assert_equal([r], plan.missions.to_a)
    end

    def test_relation_validation
	t1, t2 = prepare_plan :tasks => 2
	transaction_commit(plan, t1) do |trsc, p1|
	    trsc.add_mission(t2)
	    assert_equal(plan, t1.plan)
	    assert_equal(trsc, p1.plan)
	    assert_equal(trsc, t2.plan)
	    assert_raises(RuntimeError) { t1.depends_on t2 }
	    assert_equal(plan, t1.event(:start).plan)
	    assert_equal(trsc, p1.event(:start).plan)
	    assert_equal(trsc, t2.event(:start).plan)
	    assert_raises(RuntimeError) { t1.signals(:start, t2, :start) }
	end
    end

    def test_discard_modifications
	t1, t2, t3 = prepare_plan :missions => 1, :add => 1, :tasks => 1
	t1.depends_on t2
	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
	    p1.depends_on(t3)
	    trsc.remove_object(p1)
	    trsc.discard_modifications(t1)
	end
	assert(plan.include?(t1))
	assert_equal([t2], t1.children.to_a)
 
 	t3 = SimpleTask.new
 	transaction_commit(plan, t1, t2) do |trsc, p1, p2|
 	    p1.depends_on t3
 	    p1.remove_child p2
 	    trsc.discard_modifications(t1)
 	end
 	assert(plan.include?(t1))
 	assert_equal([t2], t1.children.to_a)
     end

    def test_plan_finalized_task
	t1, t2, t3 = prepare_plan :missions => 1, :add => 1
	t1.depends_on t2

	t3 = SimpleTask.new
	assert_raises(Roby::InvalidTransaction) do
	    transaction_commit(plan, t1, t2) do |trsc, p1, p2|
		p1.depends_on(t3)
		assert(trsc.wrap(t1, false))
		plan.remove_object(t1)
		assert(trsc.invalid?)
		assert(!trsc.wrap(t1, false))
	    end
	end
    end

    def test_plan_add_remove_invalidate
	t1 = prepare_plan :add => 1
	assert_raises(Roby::InvalidTransaction) do
	    transaction_commit(plan, t1) do |trsc, p1|
		plan.remove_object(t1)
		assert(trsc.invalid?)
	    end
	end

	t1 = prepare_plan :add => 1
	assert_nothing_raised do
	    transaction_commit(plan, t1) do |trsc, p1|
		trsc.remove_object(p1)
		plan.remove_object(t1)
		assert(!trsc.invalid?)
	    end
	end
    end

    def test_plan_relation_update_invalidate
	t1, t2 = prepare_plan :add => 2

	t1.depends_on t2
	assert_raises(Roby::InvalidTransaction) do
	    transaction_commit(plan, t1, t2) do |trsc, p1, p2|
		assert(p1.child_object?(p2, Roby::TaskStructure::Hierarchy))
		t1.remove_child t2
		assert(trsc.invalid?)
	    end
	end

	t1.depends_on t2
	assert_nothing_raised do
	    transaction_commit(plan, t1, t2) do |trsc, p1, p2|
		p1.remove_child p2
		t1.remove_child t2
		assert(!trsc.invalid?)
	    end
	end

	t1.remove_child t2
	assert_raises(Roby::InvalidTransaction) do
	    transaction_commit(plan, t1, t2) do |trsc, p1, p2|
		t1.depends_on(t2)
		assert(trsc.invalid?)
	    end
	end

	t1.remove_child t2
	assert_nothing_raised do
	    transaction_commit(plan, t1, t2) do |trsc, p1, p2|
		p1.depends_on p2
		t1.depends_on t2
		assert(!trsc.invalid?)
	    end
	end
    end
end

class TC_Transactions < Test::Unit::TestCase
    include TC_TransactionBehaviour
    include Roby::Test

    def test_and_event_aggregator
	t1, t2, t3 = (1..3).map { SimpleTask.new }
	transaction_commit(plan, t1) do |trsc, p1|
	    trsc.add_mission(t2)
	    trsc.add_mission(t3)
	    and_generator = (p1.event(:start) & t2.event(:start))
	    assert_equal(trsc, and_generator.plan)
	    and_generator.signals t3.event(:start)
	end

	t1.start!
	assert(!t3.running?)
	t2.start!
	assert(t3.running?)
    end

    def test_or_event_aggregator
	t1, t2, t3 = (1..3).map { SimpleTask.new }
	transaction_commit(plan, t1) do |trsc, p1|
	    trsc.add_mission(t2)
	    trsc.add_mission(t3)
	    (p1.event(:start) | t2.event(:start)).signals t3.event(:start)
	end

	t1.start!
	assert(t3.running?)
	assert_nothing_raised { t2.start! }
    end

    def test_commit_event_handlers
	plan.add(e = Roby::EventGenerator.new(true))
	def e.called_by_handler(mock)
	    mock.called_by_handler
	end

	FlexMock.use do |mock|
	    transaction_commit(plan, e) do |trsc, pe|
		pe.on { |ev| mock.handler_called }
		pe.on { |ev| pe.called_by_handler(mock) }
	    end

	    mock.should_receive(:handler_called).once
	    mock.should_receive(:called_by_handler).once
	    e.call(nil)
	end
    end

    def test_forwarder_behaviour
	t1, t2, t3 = (1..3).map { SimpleTask.new }

	ev = nil
	transaction_commit(plan, t1) do |trsc, p1|
	    ev = EventGenerator.new do
		p1.forward_to(:start, t2, :start)
		p1.signals(:start, t3, :start)
	    end
	    trsc.add(ev)
	    ev
	end
	ev.call

	assert(t1.event(:start).child_object?(t2.event(:start), Roby::EventStructure::Forwarding))
	assert(t1.event(:start).child_object?(t3.event(:start), Roby::EventStructure::Signal))
    end
end

class TC_RecursiveTransaction < Test::Unit::TestCase
    include TC_TransactionBehaviour
    include Roby::Test

    attr_reader :real_plan
    def engine; (real_plan || plan).engine end
    def setup
	super
        @real_plan = @plan
	@plan = Roby::Transaction.new(real_plan)
    end
    def teardown
	plan.discard_transaction
	real_plan.clear
	super
    end
end
 
