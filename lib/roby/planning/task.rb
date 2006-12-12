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

	attr_reader :planner_model, :method_name, :method_options

	def initialize(period, lookahead, planner, method_name, options = {})
	    super()

	    @period, @lookahead = period, lookahead

	    # Planner parameters
	    @planner_model, @method_name = planner.class, method_name
	    planning_options, @method_options = filter_options(options, [:planned_model])
	    @planned_model = planning_options[:planned_model]
	    
	    # Build the initial setup
	    initial_task = planner.send(method_name, method_options)
	    realized_by initial_task
	    on(:start, initial_task, :start)

	    planning_task = reschedule(initial_task)
	    on(:start, planning_task, :start)
	end

	def start(context)
	    emit(:start, context)
	    (lookahead - 1).times { reschedule }
	end
	event :start

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
	def reschedule(last_planned = nil)
	    emit :reschedule unless last_planned

	    planning = PlanningTask.new(planner_model, method_name, method_options)
	    planned  = planning.planned_task

	    last_planning = last_planning_task
	    last_planned  ||= last_planning.planned_task

	    (planning.event(:success) & 
		 last_planned.event(:success)).on(planned.event(:start), :delay => period)
	    raise if planning.event(:success).happened?
	    raise "#{last_planned} has already finished" if last_planned.event(:success).happened?

	    # There is not last_planning_task the first time
	    planned.on(:start, self, :reschedule)
	    if last_planning
		last_planning.on(:success, planning, :start)
		if last_planning.finished?
		    planning.start!
		end
	    end

	    # Add the relation last as it changes last_planning_task and
	    # last_planned_task
	    realized_by planned
	    planning

	end
	event :reschedule
    end


    # An asynchronous planning task using Ruby threads
    class PlanningTask < Roby::Task
        attr_reader :planner, :planner_model, :method_name, :method_options, :planned_model
	attr_reader :transaction

        def initialize(planner_model, method, options)
            super()
	    @planner_model = planner_model
            @method_name = method
	    planning_options, @method_options = filter_options(options, [:planned_model])

	    @planned_model = planning_options[:planned_model] || 
		planner_model.model_of(method, options).returns ||
		Task
        end

	def to_s
	    "#{super}[#{method_name}:#{method_options}] -> #{@planned_task || "nil"}"
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
	    @transaction = Transaction.new(plan)
	    @planner     = planner_model.new(transaction)

	    @thread = Thread.new do
		@result = begin
			      @planner.send(@method_name, @method_options)
			  rescue Exception => e; e
			  end
	    end
	    PlanningTask.planning_tasks << self
	    emit(:start)
        end
        event :start

	# Polls for the planning thread end
	def poll
	    return if thread.alive?

	    begin
		case result
		when Planning::PlanModelError
		    transaction.discard_transaction
		    emit(:failed, result)
		when Roby::Task
		    transaction.replace(transaction[planned_task], result)
		    transaction.commit_transaction
		    emit(:success)
		else
		    raise result, "expected a planning exception or a Task, got #{result} in #{caller[0]}", result.backtrace
		end

	    ensure
		@thread = nil
		PlanningTask.planning_tasks.delete(self)

		# Make sure the transaction will be finalized event if the 
		# planning task is not removed from the plan
		@transaction = nil
		@planner = nil
	    end
	end

	# Stops the planning thread
        def stop(context); thread.kill end
        event :stop

	class TransactionProxy < Roby::Transactions::Task
	    proxy_for PlanningTask
	    def_delegator :@__getobj__, :planner
	    def_delegator :@__getobj__, :method_name
	    def_delegator :@__getobj__, :method_options
	end
    end
end

