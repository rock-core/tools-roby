require 'roby/task'
require 'roby/relations/planned_by'
require 'roby/control'
require 'roby/transactions'

module Roby
    # An asynchronous planning task using Ruby threads
    class PlanningTask < Roby::Task
        attr_reader :planner, :method_name, :method_options, :every, :planned_model

	# The transaction (or transaction) we are acting on
	attr_reader :transaction

        def initialize(plan, planner_model, method, options)
            super()
	    @transaction = Transaction.new(plan)
	    @planner   = planner_model.new(transaction)

            @method_name = method
	    planning_options, @method_options = filter_options(options, [:every, :planned_model])

	    @every = planning_options[:every]
	    @planned_model = planning_options[:planned_model] || 
		planner_model.model_of(method, options).returns
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

	def planned_task
	    task = super
	    if !task
		task = planned_model.new
		task.planned_by self
		task.executable = false
	    end

	    task
	end

	# The thread that is running the planner
        attr_reader :thread
	# The planner result. It is either an exception or a task object
	attr_reader :result

	# Starts planning
        def start(context)
	    if planned_task.running?
		reschedule
	    else
		@thread = Thread.new do
		    @result = begin
				  @planner.send(@method_name, @method_options)
			      rescue Exception => e; e
			      end
		end
		PlanningTask.planning_tasks << self
	    end
	    emit(:start, context)
        end
        event :start

	# Polls for the planning thread end
	def poll
	    return if thread.alive?

	    @thread = nil
	    PlanningTask.planning_tasks.delete(self)

	    case result
	    when Planning::PlanModelError
		transaction.discard_transaction
		emit(:failed, task.result)
	    when Roby::Task
		transaction.replace(transaction[planned_task], result)
		reschedule if every
		transaction.commit_transaction
		emit(:success)
	    else
		raise result, "expected an exception or a Task, got #{result} in #{caller[0]}", result.backtrace
	    end
	end

	# Reschedule a planner in case we are planning loops
	def reschedule
	    if every == 0
		planning = PlanningTask.new(transaction.real_plan, planner.class, method_name, 
			method_options.merge(:every => every, :planned_model => planned_model))
		new_planned_task = planning.planned_task # make planning create its planned_task

		if plan.mission?(planned_task)
		    transaction.insert(new_planned_task)
		else
		    transaction.discover(new_planned_task)
		end

		(planning.event(:success) & transaction[self].planned_task.event(:success)).on new_planned_task.event(:start)
		transaction[self].on(:success, planning, :start)

	    else
		raise NotImplementedError
	    end
	end

	# Stops the planning thread
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

