module Roby
    # An asynchronous planning task using Ruby threads
    class PlanningTask < Roby::Task
	attr_reader :planner, :transaction

	argument :planner_model
        argument :method_options
        argument :method_name
        argument :planned_model
        argument :planning_owners
        argument :planning_method, :default => nil

        def self.validate_planning_options(options)
            options = options.dup
            if options[:method_name]
                method_name = options[:planning_method] = options[:method_name]
            elsif options[:planning_method].respond_to?(:to_str) || options[:planning_method].respond_to?(:to_sym)
                method_name = options[:method_name] = options[:planning_method].to_s
            end

	    if !options[:planner_model]
		raise ArgumentError, "missing required argument 'planner_model'"
	    elsif !options[:planning_method]
		raise ArgumentError, "missing required argument 'planning_method'"
            elsif !method_name
                if options[:planning_method]
                    options[:method_name] = options[:planning_method].name
                else
                    raise ArgumentError, "the planning_method argument is neither a method object nor a name: got #{options[:planning_method]}"
                end
	    end

            if options[:planning_method].respond_to?(:to_sym)
                options[:planning_method] = options[:planning_method].to_s
            end

            options[:planned_model] ||= nil
	    options[:planning_owners] ||= nil
            options
        end

	def self.filter_options(options)
	    task_options, method_options = Kernel.filter_options options,
		:planner_model => nil,
		:planning_method => nil,
		:method_options => {},
                :method_name => nil, # kept for backward compatibility
		:planned_model => nil,
		:planning_owners => nil

            task_options = validate_planning_options(task_options)
	    task_options[:planned_model] ||= 
                if !task_options[:planning_method].respond_to?(:to_str)
                    task_options[:planning_method].returned_type
                elsif task_options[:method_name]
                    task_options[:planner_model].model_of(task_options[:method_name], method_options).returned_type
                end
            task_options[:planned_model] ||= Roby::Task

	    task_options[:method_options] ||= Hash.new
	    task_options[:method_options].merge! method_options
	    task_options
	end

        def initialize(options)
	    task_options = PlanningTask.filter_options(options)
            super(task_options)
	end

	def to_s
	    "#{super}[#{planning_method}:#{method_options}] -> #{planned_task || "nil"}"
	end

	def planned_task
	    if success? || result
		result
	    elsif task = planned_tasks.find { true }
		task
	    elsif pending?
		task = planned_model.new
		task.planned_by self
		task.abstract = true
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
	    result_task = if planning_method.respond_to?(:to_str)
                              planner.send(method_name, method_options.merge(:context => context))
                          else
                              planner.send(:call_planning_methods, Hash.new, method_options.merge(:context => context), planning_method)
                          end

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
	    if transaction.committed?
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
    end
end

