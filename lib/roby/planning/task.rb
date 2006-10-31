require 'roby/task'
require 'roby/relations/planned_by'
require 'roby/control'
require 'roby/transactions'

module Roby
    class PlanningLoop < Roby::Task
	# The period. Zero means continuously
	attr_reader :period
	# How many loops do we unroll
	attr_reader :lookahead

	attr_reader :plan, :planner_model, :method_name, :method_options

	def initialize(repeat, lookahead, plan, planner, method_name, method_options = {})
	    super()

	    # Loop parameters
	    raise NotImplementedError, "repeat should be zero" unless repeat == 0
	    @repeat, @lookahead = repeat, lookahead

	    # Planner parameters
	    @plan, @planner_model, @method_name, @method_options = 
		plan, planner.class, method_name, method_options
	    
	    # Build the initial setup
	    initial_task = planner.send(method_name, method_options)
	    realized_by initial_task
	    on(:start, initial_task, :start)

	    planning_task = reschedule(initial_task)
	    on(:start, planning_task, :start)
	    (lookahead - 1).times { reschedule(self.last_planned_task) }
	end

	event(:start, :command => true)
	event(:failed, :command => true, :terminal => true)
	def stop(context); failed!  end
	event(:stop, :terminal => true)

	def each_pattern_planning
	    children.each do |child|
		planning = child.planning_task
		yield(planning) if planning
	    end
	end

	# The last planned task
	def last_planned_task; last_planning_task.planned_task end
	# The last PlanningTask object
	def last_planning_task
	    enum_for(:each_pattern_planning).find do |planning|
		!enum_for(:each_pattern_planning).find do |t| 
		    planning.event(:success).child_object?(t.event(:start), EventStructure::Signal)
		end
	    end
	end
	
	# Creates one pattern at the end of the already developed patterns.
	# Returns the new planning task
	def reschedule(last_planned_task)
	    planning = PlanningTask.new(plan, planner_model, method_name, method_options)
	    planned  = planning.planned_task

	    (planning.event(:success) & 
		 last_planned_task.event(:success)).on planned.event(:start)

	    # There is not last_planning_task the first time
	    if last_planning_task = self.last_planning_task
		last_planning_task.on(:success, planning, :start)
	    end
	    planning.on(:success) { reschedule(self.last_planned_task) }

	    # Add the relation last as it changes last_planning_task and last_planned_task
	    realized_by planned
	    planning
	end
    end


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
		planner_model.model_of(method, options).returns ||
		Task
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
		transaction.commit_transaction
		emit(:success)
	    else
		raise result, "expected an exception or a Task, got #{result} in #{caller[0]}", result.backtrace
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

