module Roby
    class DecisionControl
        # Called when there is a conflict between a set of running tasks and a
        # task that should have been started. The default operation is to
        # postpone starting the task until all the conflicting tasks are
        # finished
	def conflict(starting_task, running_tasks)
	    for t in running_tasks
		starting_task.event(:start).postpone t.event(:stop)
		return
	    end
	end

        # Called when a transaction/execution conflict occured, where a task
        # included in the transaction has been removed from the plan.
        #
        # +proxy+ is the transaction's representation of the task which has
        # been removed and +transaction+ the transaction. The transaction has
        # been invalidated prior to this call, and the task proxy has been
        # removed from +transaction+.
        #
        # The default action is to do nothing
        def finalized_plan_task(transaction, proxy)
        end

        # Called when a transaction/execution conflict occured, where a task
        # included in the transaction has been removed from the plan.
        #
        # +proxy+ is the transaction representation of the event which has been
        # removed and +transaction+ the transaction. The transaction has been
        # invalidated prior to this call, and the event proxy has been removed
        # from +transaction+.
        #
        # The default action is to do nothing
        def finalized_plan_event(transaction, proxy)
	end

        # Called when a transaction/execution conflict occured, where relations
        # have been added in the plan and are not present in the transaction.
        #
        # The new relations are of types +relations+, between +parent+ and
        # +child+ and with +info+ as info object. The transaction has been
        # invalidated prior to this call
        #
        # The default action is to do nothing
	def adding_plan_relation(transaction, parent, child, relations, info)
	end

        # Called when a transaction/execution conflict occured, where relations
        # have been removed from the plan, which were present in the
        # transaction.
        #
        # The relations are of types +relations+, between +parent+ and +child+
        # and with +info+ as info object. The transaction has been invalidated
        # prior to this call
        #
        # The default action is to do nothing
	def removing_plan_relation(transaction, parent, child, relations)
        end
    end

    class << self
	attr_reader :control

        def control=(new)
            if control
                raise ArgumentError, "cannot change the decision control object"
            elsif engine && new != engine.control
                raise ArgumentError, "must have Roby.control == Roby.engine.control"
            end

            @control = new
        end
    end
end

