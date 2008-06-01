require 'roby/task'
require 'roby/relations/planned_by'
require 'roby/control'
require 'roby/transactions'

module Roby
    # An asynchronous planning task using Ruby threads
    class PlanningTask < Roby::Task
	attr_reader :planner, :transaction

	arguments :planner_model, :method_name, 
	    :method_options, :planned_model, 
	    :planning_owners

	def self.filter_options(options)
	    task_options, method_options = Kernel.filter_options options,
		:planner_model => nil,
		:method_name => nil,
		:method_options => {},
		:planned_model => nil,
		:planning_owners => nil

	    if !task_options[:planner_model]
		raise ArgumentError, "missing required argument 'planner_model'"
	    elsif !task_options[:method_name]
		raise ArgumentError, "missing required argument 'method_name'"
	    end
	    task_options[:planned_model] ||= nil
	    task_options[:method_options] ||= Hash.new
	    task_options[:method_options].merge! method_options
	    task_options[:planning_owners] ||= nil
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
	    if success? || result
		result
	    elsif task = planned_tasks.find { true }
		task
	    elsif pending?
		task = planned_model.new
		task.planned_by self
		task.executable = false
		task
	    end
	end

	# The thread that is running the planner
        attr_reader :thread
	# The transaction in which we build the new plan. It gets committed on
	# success.
	attr_reader :transaction
	# The planner result. It is either an exception or a task object
	attr_reader :result

	# Starts planning
        event :start do |context|
	    emit :start

	    if planning_owners
		@transaction = Distributed::Transaction.new(plan)
		planning_owners.each do |peer|
		    transaction.add_owner peer
		end
	    else
		@transaction = Transaction.new(plan)
	    end
	    @planner = planner_model.new(transaction)

	    @thread = Thread.new do
		Thread.current.priority = 0
		planning_thread(context)
	    end
        end

	def planning_thread(context)
	    result_task = planner.send(method_name, method_options.merge(:context => context))

	    # Don't replace the planning task with ourselves if the
	    # transaction specifies another planning task
	    if !result_task.planning_task
		result_task.planned_by transaction[self]
	    end

	    if placeholder = planned_task
		placeholder = transaction[placeholder]
		transaction.replace(placeholder, result_task)
		placeholder.remove_planning_task transaction[self]
	    end

	    # If the transaction is distributed, and is not proposed to all
	    # owners, do it
	    transaction.propose
	    transaction.commit_transaction do
		@result = result_task
	    end
	end

	# Polls for the planning thread end
	poll do
	    if thread.alive?
		return 
	    end

	    # Check if the transaction has been committed. If it is not the
	    # case, assume that the thread failed
	    if transaction.freezed?
		emit :success
	    else
		error = begin
			    thread.value
			rescue Exception => e
			    @result = e
			end

		transaction.discard_transaction
		emit :failed, error
	    end
	end

	# Stops the planning thread
        event :stop do |context|
	    planner.stop
	end
	on :stop do |ev|
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

