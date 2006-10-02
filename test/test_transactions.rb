require 'roby/transactions'
require 'test_plan.rb'

# Check that a transaction behaves like a plan
class TC_TransactionAsPlan < Test::Unit::TestCase
    include TC_PlanStatic

    def setup
	@real_plan = Plan.new
	@plan = Transaction.new(@real_plan)
    end
    def teardown
	@plan.commit
    end
end


class TC_Transactions < Test::Unit::TestCase
    include Roby::Transactions

    def transaction_commit(plan)
	trsc = Roby::Transaction.new(plan)
	yield(trsc)
	trsc.commit
    end

    # Tests insertion and removal of tasks
    def test_add_remove
	plan = Roby::Plan.new
	t1, t2, t3 = (1..3).map { Roby::Task.new }
	plan.insert(t1)

	transaction_commit(plan) do |trsc|
	    assert(trsc.include?(t1))
	    assert(trsc.mission?(t1))
	    assert(trsc.include?(Proxy.wrap(t1)))
	    assert(trsc.mission?(Proxy.wrap(t1)))
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
	    trsc.remove_task(Proxy.wrap(t3)) 
	    assert(!trsc.include?(t3))
	    assert(plan.include?(t3))
	end
	assert(!plan.include?(t3))
	assert(!plan.mission?(t3))
    end
end

