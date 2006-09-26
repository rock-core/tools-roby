require 'roby/transactions/proxy'
require 'roby/plan'

module Roby
    # A transaction is a special kind of plan. It allows to build plans in a separate
    # sandbox, and then to apply the modifications to the real plan (using #commit), or
    # to discard all modifications (using #discard)
    class Transaction < Plan
	def [](object)
	    if object.class.has_ancestor?(Proxy)
		object
	    else
		Transactions::Proxy.wrap(object)
	    end
	end

	attr_reader :plan
	def initialize(plan)
	    @plan = plan
	end

	def missions
	    super | plan.missions.map(&Proxy.method(:wrap))
	end
	def known_tasks
	    super | plan.known_tasks.map(&Proxy.method(:wrap))
	end
    end
end

