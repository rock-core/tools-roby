require 'roby/task'
require 'roby/relations/planned_by'
require 'roby/control'
require 'roby/transactions'

module Roby
    class PlanningLoop < Roby::Task
	terminates

	# The period. Zero means continuously
	attr_reader :period
	# How many loops do we have unroll
	attr_reader :lookahead
	# How many loops are currently unrolled
	attr_accessor :pending_patterns

	attr_reader :planner_model, :method_name, :method_options

	# For periodic updates. If false, the next loop is started when the
	# 'loop_start' command is called
	argument :period
	# How many loops should we have unrolled at all times
	argument :lookahead

	# The task model we should produce
	argument :planned_model
	# The planner model we should use
	argument :planner_model
	# The planner method name
	argument :method_name
	# The planner method options
	argument :method_options

	def self.filter_options(options)
	    task_arguments, planning_options = Kernel.filter_options options, 
		:period => nil,
		:lookahead => 1,
		:planner => nil,
		:planned_model => Roby::Task,
		:planned_task => nil,
		:method_name => nil,
		:method_options => {}

	    if !task_arguments[:method_name]
		raise ArgumentError, "required argument :method_name missing"
	    elsif !task_arguments[:planner]
		raise ArgumentError, "required argument :planner missing"
	    elsif task_arguments[:lookahead] < 1
		raise ArgumentError, "lookahead must be at least 1"
	    end
	    [task_arguments, planning_options]
	end

	def initialize(options)
	    task_arguments, planning_options = PlanningLoop.filter_options(options)

	    planner      = task_arguments.delete(:planner)
	    planned_task = task_arguments.delete(:planned_task)
	    task_arguments[:planner_model] = planner.class
	    task_arguments[:method_options].merge!(planning_options)

	    super(task_arguments)

	    @period, @lookahead, @planner_model, @method_name, @method_options, @planned_model = 
		arguments.values_at(:period, :lookahead, :planner_model, :method_name, :method_options, :planned_model)

	    if planned_task
		planned_task.planned_by self
	    end
	    
	    @pending_patterns = 0
	    @start_next_loop  = EventGenerator.new

	    # Build the initial setup
	    initial_task = planner.send(method_name, method_options)
	    main_task.realized_by initial_task
	    on(:start, initial_task, :start)
	    initial_task.forward(:start, self, :loop_start)
	    initial_task.forward(:success, self, :loop_end)

	    planning_task = reschedule(nil, initial_task)
	    on(:start, planning_task, :start)

	    (lookahead - 1).times { reschedule }
	end

	# The task on which the children are added
	def main_task; planned_task || self end

	# Enumerates the PlanningTask we have currently added to the plan
	def each_pattern_planning
	    main_task.children.each do |child|
		planning = child.planning_task
		if planning && 
		    planning.planner_model == planner_model &&
		    planning.method_name == method_name &&
		    planning.method_options == method_options
		    yield(planning)
		end
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
	def reschedule(context = nil, last_planned = nil)
	    emit :reschedule unless last_planned

	    return if self.pending_patterns >= lookahead
	    self.pending_patterns += 1

	    planning = PlanningTask.new(:planner_model => planner_model, :method_name => method_name, :method_options => method_options)
	    planned  = planning.planned_task

	    last_planning = last_planning_task
	    last_planned  ||= last_planning.planned_task

	    start_next = planning.event(:success)
	    unless last_planned.event(:success).happened?
		start_next &= last_planned.event(:success)
	    end
	    start_next = if period
			     start_next.delay(period) | (start_next & @start_next_loop)
			 else
			     start_next & @start_next_loop
			 end
	    start_next.on(planned.event(:start))

	    planned.forward(:start, self, :loop_start)
	    planned.forward(:success, self, :loop_end)

	    # There is no last_planning_task the first time
	    planned.on(:start, self, :reschedule)
	    if last_planning
		last_planning.on(:success, planning, :start)
		if last_planning.finished?
		    planning.start!
		end
	    end

	    main_task.remove_finished_children

	    # Add the relation last as it changes last_planning_task and
	    # last_planned_task
	    main_task.realized_by planned
	    planning
	end
	event :reschedule

	def loop_start(context)
	    @start_next_loop.emit(context)
	end
	event :loop_start
	on(:loop_start) { |event| event.task.pending_patterns -= 1 }
	event :loop_end
    end


    # An asynchronous planning task using Ruby threads
    class PlanningTask < Roby::Task
        attr_reader :planner_model, :method_name, :method_options, :planned_model
	attr_reader :planner, :transaction

	argument :planner_model, :method_name, :method_options, :planned_model

	def self.filter_options(options)
	    task_options, method_options = Kernel.filter_options options,
		:planner_model => nil,
		:method_name => nil,
		:method_options => {},
		:planned_model => nil

	    if !task_options[:planner_model]
		raise ArgumentError, "missing required argument 'planner_model'"
	    elsif !task_options[:method_name]
		raise ArgumentError, "missing required argument 'method_name'"
	    end
	    [task_options, method_options]
	end

        def initialize(options)
	    task_options, planning_options = PlanningTask.filter_options(options)
            super(task_options)

	    @planner_model, @method_name, @method_options, @planned_model =
		task_options.values_at(:planner_model, :method_name, :method_options, :planned_model)

	    @method_options.merge!(planning_options)
	    @planned_model ||= planner_model.model_of(method_name, method_options).returns || Roby::Task
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
		when Roby::Task
		    transaction.replace(transaction[planned_task], result)
		    transaction.commit_transaction
		    emit(:success)
		else
		    transaction.discard_transaction
		    emit(:failed, result)
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

