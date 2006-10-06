require 'roby/task'
require 'roby/relations/planned_by'
require 'roby/control'
require 'roby/transactions'

module Roby
    # An asynchronous planning task using Ruby threads
    class PlanningTask < Roby::Task
        attr_reader :planner, :method_name, :method_options
        def initialize(plan, planner_model, method, options)
	    @planner = planner_model.new(Transaction.new(plan))
            @method_name, @method_options = method, options
            super()
        end

	def to_s
	    "#{super}[#{method_name}:#{method_options}] -> #{planned_task}"
	end

        @planning_tasks = Array.new
        class << self
            attr_reader :planning_tasks
        end

        Control.event_processing << lambda do 
            planning_tasks.each { |task| task.poll }
        end

        attr_reader :thread, :result
        def start(context)
	    if !planned_task
		raise TaskModelViolation.new(self), "we are not planning any task"
	    end

            @thread = Thread.new do
		@result = begin
			      @planner.send(@method_name, @method_options)
			  rescue Exception => e; e
			  end
            end
            PlanningTask.planning_tasks << self
            emit(:start, context)
        end
        event :start

	def poll
	    return if thread.alive?

	    @thread = nil
	    PlanningTask.planning_tasks.delete(self)

	    case result
	    when Planning::PlanModelError
		planner.plan.discard_transaction
		emit(:failed, task.result)
	    when Roby::Task
		plan = planner.plan
		plan.replace(plan[planned_task], result)
		plan.commit_transaction
		emit(:success)
	    else
		raise result, "expected an exception or a Task, got #{result} in #{caller[0]}", result.backtrace
	    end
	end

        def stop(context); thread.kill end
        event :stop

	class TransactionProxy < Transactions::Task
	    proxy_for PlanningTask
	    def_delegator :@__getobj__, :planner
	    def_delegator :@__getobj__, :method_name
	    def_delegator :@__getobj__, :method_options
	end
    end
end

