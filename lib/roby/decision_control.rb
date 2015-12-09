module Roby
    class DecisionControl
        # Called when there is a conflict between a set of running tasks and a
        # task that should have been started. The default operation is to
        # add an error about it
	def conflict(starting_task, running_tasks)
            starting_task.failed_to_start! TaskStructure::ConflictError.new(starting_task, running_tasks)
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

        # Called when a child failed a dependency relation, but the parent is
        # not running
        #
        # It must return true if the dependency failure is considered an error,
        # and false otherwise.
        #
        # The default policy is to mark the parent as failed to start
        def pending_dependency_failed(parent, child, reason)
            parent.failed_to_start!(reason)
            true
        end

        # Called when an execution agent fails to start.
        #
        # The default policy is to mark all executed tasks as failed to start
        def pending_executed_by_failed(agent, tasks)
            tasks.each do |t|
                t.failed_to_start!(agent.failure_reason || agent.terminal_event)
            end
        end

        # Called when an execution agent fails to start.
        #
        # The default policy is to mark all executed tasks as failed to start
        def execution_agent_failed_to_start(agent, tasks)
            tasks.each do |t|
                info = t[agent, Roby::TaskStructure::ExecutionAgent]
                if !info[:respawn]
                    t.failed_to_start!(agent.failure_reason || agent.terminal_event)
                end
            end
        end
    end
end

