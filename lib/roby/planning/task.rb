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

	# An array of [planning_task, user_command]. The *last* element is the
	# *first* arrived
	attr_reader :patterns

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

	# Filters the options in +options+, splitting between the options that
	# are specific to the planning task and those that are to be forwarded
	# to the planner itself
	def self.filter_options(options) # :nodoc:
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
	    
	    @patterns = []
	end

	# The task on which the children are added
	def main_task; planned_task || self end
	
	def planned_task # :nodoc:
	    planned_tasks.find { true } 
	end

	# The last PlanningTask object
	def last_planning_task
	    if pattern = patterns.first
		pattern.first
	    end
	end

	# Appends a new unplanned pattern after all the patterns already developped
	#
	# +context+ is forwarded to the planned task
	def append_pattern(*context)
	    # Create the new pattern
	    task_arguments = arguments.slice(:planner_model, :planned_model, :method_name)
	    task_arguments[:method_options] = method_options.dup
	    task_arguments[:method_options][:first_pattern] = !@did_once
	    @did_once = true

	    planning = PlanningTask.new(task_arguments)
	    planned  = planning.planned_task
	    planned.forward(:start,   self, :loop_start)
	    planned.forward(:success, self, :loop_success)
	    planned.forward(:stop,    self, :loop_end)
	    main_task.realized_by planned
	    
	    # Schedule it. We start the new pattern when these three conditions are met:
	    #	* it has been planned (planning has finished)
	    #	* the previous one (if any) has finished
	    #	* the period (if any) has expired or loop_start has been called
	    precondition = planning.event(:success)
	    # this event is used to start the next pattern
	    user_command = EventGenerator.new(true)

	    if last_planning = last_planning_task
		last_planned = last_planning.planned_task

		unless last_planned.finished?
		    precondition &= last_planned.event(:stop)
		end

		command = precondition & user_command
		if period
		    command |= precondition.delay(period)
		end

		if last_planning.success?
		    planning.start!(*context) 
		else
		    last_planning.event(:success).filter(*context).on(planning.event(:start))
		end
	    else
		command = precondition & user_command
	    end

	    patterns.unshift([planning, user_command])
	    command.on(planned.event(:start))
	    planning
	end

	# Remove all pending patterns, unroll as much patterns as lookahead
	# requires.  Kills the currently running pattern (if there is one)
	def reinit
	    return unless running?

	    count = patterns.size
	    while !patterns.empty?
		planning_task, command = patterns.first
		task = planning_task.planned_task
		main_task.remove_child task

		if task.running?
		    break
		else
		    patterns.shift
		end
	    end

	    has_running_task = !patterns.empty?
	    first_planning_task = nil
	    while patterns.size < count
		new_planning = append_pattern
		first_planning ||= new_planning
	    end
	    if !has_running_task && count > 0
		first_planning.start!
	    end
	end

	# Generates the first +lookahead+ patterns and start planning. The
	# tasks are started when +loop_start+ is called.
	event :start do
	    if lookahead > 0
		first_planning = nil
		while patterns.size < lookahead
		    new_planning = append_pattern
		    first_planning ||= new_planning
		end
		on(:start, first_planning)
	    end

	    emit :start
	end

	event :loop_start do |context|
	    if lookahead == 0
		start_planning = !last_planning_task
		planning = append_pattern(*context)
		if start_planning
		    planning.start!(*context)
		end
	    end

	    # Find the first non-running pattern and start it
	    patterns.reverse.each do |task, ev|
		unless ev.happened?
		    ev.call(*context)
		    break
		end
	    end
	end
	on :loop_start do |event| 
	    return unless self_owned?
	    append_pattern unless event.task.lookahead == 0
	    main_task.remove_finished_children
	end

	event :loop_success

	event :loop_end
	on :loop_end do |event|
	    return unless self_owned?
	    patterns.pop
	end

	# For ordering during event propagation
	causal_link :loop_start => :loop_end
	causal_link :loop_success => :loop_end
    end


    # An asynchronous planning task using Ruby threads
    class PlanningTask < Roby::Task
	attr_reader :planner, :transaction

	arguments :planner_model, :method_name, :method_options, :planned_model

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
	    task_options[:method_options] ||= Hash.new
	    task_options[:method_options].merge! method_options
	    task_options
	end

        def initialize(options)
	    task_options = PlanningTask.filter_options(options)
            super(task_options)
        end

	def planned_model
	    arguments[:planned_model] ||= planner_model.model_of(method_name, method_options).returns || Roby::Task
	end


	def to_s
	    "#{super}[#{method_name}:#{method_options}] -> #{@planned_task || "nil"}"
	end

	def planned_task
	    task = planned_tasks.find { true }
	    if !task && pending?
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
        event :start do |context|
	    emit(:start)

	    @transaction = Transaction.new(plan)
	    @planner     = planner_model.new(transaction)

	    @thread = Thread.new do
		Thread.current.priority = 0
		@result = begin
			      @planner.send(method_name, method_options.merge(:context => context))
			  rescue Exception => e; e
			  end
	    end
        end

	# Polls for the planning thread end
	poll do
	    if thread.alive?
		return 
	    end

	    case result
	    when Roby::Task
		# Don't replace the planning task with ourselves if the
		# transaction specifies another planning task
		if !result.planning_task
		    result.planned_by transaction[self]
		end

		if placeholder = planned_task
		    placeholder = transaction[placeholder]
		    transaction.replace(placeholder, result)
		    placeholder.remove_planning_task transaction[self]
		end
		transaction.commit_transaction
		emit(:success)
	    else
		transaction.discard_transaction
		emit(:failed, result)
	    end
	end

	# Stops the planning thread
        event :stop do 
	    thread.kill 
	end
	on(:stop) do
	    # Make sure the transaction will be finalized event if the 
	    # planning task is not removed from the plan
	    @transaction = nil
	    @planner = nil
	    @thread = nil
	end

	class TransactionProxy < Roby::Transactions::Task
	    proxy_for PlanningTask
	    def_delegator :@__getobj__, :planner
	    def_delegator :@__getobj__, :method_name
	    def_delegator :@__getobj__, :method_options
	end
    end
end

