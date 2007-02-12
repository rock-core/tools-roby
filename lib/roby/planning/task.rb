require 'roby/task'
require 'roby/relations/planned_by'
require 'roby/control'
require 'roby/transactions'

module Roby
    # This class unrolls a loop in the plan. It maintains +lookahead+ patterns
    # developped at all times by calling an external planner, and manages the
    # resulting tasks. 
    #
    # The first patterns are developped when +start+ is called. You must then
    # call +loop_start+ to start the generated tasks.
    #
    # If the PlanningLoop task is planning a task, then the generated tasks are
    # added as child of this task. Otherwise, they are children of the
    # PlanningLoop itself.
    class PlanningLoop < Roby::Task
	terminates

	# The period. Zero means continuously and false 'on demand'
	attr_reader :period
	# How many loops do we have unroll
	attr_reader :lookahead

	# How many loops are currently unrolled
	def pending_patterns; start_commands.size end

	# An queue of event generators. Each generator starts the next pending
	# loop
	attr_accessor :start_commands
	private :start_commands

	# For periodic updates. If false, the next loop is started when the
	# 'loop_start' command is called
	argument :period
	# How many loops should we have unrolled at all times
	argument :lookahead

	# The task model we should produce
	argument :planned_model

	attr_reader :planner_model, :method_name, :method_options
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
		:planner_model => nil,
		:planned_model => Roby::Task,
		:method_name => nil,
		:method_options => {}

	    if !task_arguments[:method_name]
		raise ArgumentError, "required argument :method_name missing"
	    elsif !task_arguments[:planner_model]
		raise ArgumentError, "required argument :planner_model missing"
	    elsif task_arguments[:lookahead] < 0
		raise ArgumentError, "lookahead must be positive"
	    end
	    task_arguments[:period] ||= nil
	    [task_arguments, planning_options]
	end

	def initialize(options)
	    task_arguments, planning_options = PlanningLoop.filter_options(options)
	    task_arguments[:method_options].merge!(planning_options)

	    super(task_arguments)

	    @period, @lookahead, @planner_model, @method_name, @method_options, @planned_model = 
		arguments.values_at(:period, :lookahead, :planner_model, :method_name, :method_options, :planned_model)
	    
	    @start_commands = []
	end

	# The task on which the children are added
	def main_task; planned_task || self end

	# Appends a new unplanned pattern after all the patterns already developped
	def append_pattern(context = nil)
	    # Create the new pattern
	    planning = PlanningTask.new(arguments.slice(:planner_model, :planned_model, :method_name, :method_options))
	    planned  = planning.planned_task
	    planned.forward(:start, self, :loop_start)
	    planned.forward(:success, self, :loop_end)
	    
	    # Schedule it. We start the new pattern when these three conditions are met:
	    #	* it has been planned (planning has finished)
	    #	* the previous one (if any) has finished
	    #	* the period (if any) has expired or loop_start has been called
	    start_next = planning.event(:success)
	    # this event is used to start the next pattern
	    start_next_loop = EventGenerator.new(true)

	    if last_planning = last_planning_task
		last_planned = last_planning.planned_task
		unless last_planned.success?
		    start_next &= last_planned.event(:success)
		end
		if period
		    start_next = start_next.delay(period) | (start_next & start_next_loop)
		else
		    start_next &= start_next_loop
		end

		if last_planning.success?
		    planning.start!(context) 
		else
		    last_planning.event(:success).filter(context).on(planning.event(:start))
		end
	    else
		start_next &= start_next_loop
	    end

	    start_commands.unshift(start_next_loop)

	    main_task.realized_by planned
	    start_next.on(planned.event(:start))
	    planning
	end

	# Generates the first +lookahead+ pattens and start planning the first.
	# The first tasks are started when +loop_start+ is called, not before.
	def start(context)
	    first_planning = nil
	    if lookahead > 0
		while pending_patterns < lookahead
		    new_planning = append_pattern
		    first_planning ||= new_planning
		end
		on(:start, first_planning)
	    end

	    emit :start, context
	end
	event :start

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
	def last_planned_task
	    if last_planning_task
		last_planning_task.planned_task 
	    end
	end
	# The last PlanningTask object
	def last_planning_task
	    enum_for(:each_pattern_planning).find do |planning|
		!enum_for(:each_pattern_planning).find do |t| 
		    planning.event(:success).child_object?(t.event(:start), EventStructure::Signal)
		end
	    end
	end
	
	def loop_start(context)
	    if lookahead == 0
		start_planning = !last_planning_task
		planning = append_pattern(context)
		if start_planning
		    planning.start!(context)
		end
		start_commands.first.call(context)
	    else
		start_commands.last.call(context)
	    end
	end
	event :loop_start
	on(:loop_start) do |event| 
	    event.task.instance_eval do
		start_commands.pop
		append_pattern unless event.task.lookahead == 0
		main_task.remove_finished_children
	    end
	end

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
	    task_options[:planned_model] ||= nil
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
            planning_tasks.delete_if do |task| 
		if task.thread.alive?
		    false
		else
		    task.poll
		    true
		end
	    end
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
			      @planner.send(@method_name, @method_options.merge(:context => context))
			  rescue Exception => e; e
			  end
	    end
	    PlanningTask.planning_tasks << self
	    emit(:start)
        end
        event :start

	# Polls for the planning thread end
	def poll
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
	    # Make sure the transaction will be finalized event if the 
	    # planning task is not removed from the plan
	    @thread = nil
	    @transaction = nil
	    @planner = nil
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

