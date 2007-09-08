require 'roby/task'

module Roby::TaskStructure
    # This module defines model-level definition of execution agent, for
    # instance to Roby::Task
    module ModelLevelExecutionAgent
	# The model of execution agent for this class
	def execution_agent
	    for klass in ancestors
		if klass.instance_variable_defined?(:@execution_agent)
		    return klass.instance_variable_get(:@execution_agent)
		end
	    end
	    nil
	end

	# Defines a model of execution agent. Doing
	#
	#   TaskModel.executed_by ExecutionAgentModel
	#
	# is equivalent to
	#
	#   task = TaskModel.new
	#   exec = <find a suitable ExecutionAgentModel instance in the plan or
	#	   create a new one>
	#   task.executed_by exec
	#   
	# for all instances of TaskModel. The actual job is done in the
	# ExecutionAgentSpawn module
	def executed_by(agent)
	    @execution_agent = agent
	end
    end

    # The execution_agent defines an agent (process or otherwise) a given
    # task is executed by. It allows to define a class of these execution agent,
    # so that the specific agents are managed externally (load-balancing, ...)
    relation :ExecutionAgent, :parent_name => :executed_task, :child_name => :execution_agent, 
	:noinfo => true, :distribute => false, :single_child => true do
	
	# When ExecutionAgent support is included in a model (for instance Roby::Task), add
	# the model-level classes  
        def self.included(klass) # :nodoc:
	    klass.extend Roby::TaskStructure::ModelLevelExecutionAgent
            super
        end

	# Defines a new execution agent for this task.
        def executed_by(agent)
	    return if execution_agent == agent
	    if !agent.event(:start).controlable? && !agent.running?
		raise TaskModelViolation.new(self), "the start event of #{self}'s execution agent #{agent} is not controlable"
	    end
	    # Check that agent defines the :ready event
	    if !agent.has_event?(:ready)
		raise ArgumentError, "execution agent tasks should define the :ready event"
	    end
	    
	    old_agent = execution_agent
	    if old_agent && old_agent != agent
		Roby.debug "an agent is already defined for this task"
		remove_execution_agent old_agent
	    end

	    unless old_agent
		# If the task did have an agent already, these event handlers
		# are already set up
		if running?
		    Roby::Distributed.update(self) do
			agent.forward(:stop, self, :aborted)
		    end
		else
		    on(:start) do
			# The event handler will be called even if the
			# execution agent has been removed. Check that there is
			# actually an execution agent 
			if execution_agent
			    Roby::Distributed.update(self) do
				execution_agent.forward(:stop, self, :aborted)
			    end
			end
		    end
		end

		on(:stop) do 
		    if execution_agent
			Roby::Distributed.update(self) do
			    execution_agent.event(:stop).remove_forwarding event(:aborted)
			    remove_execution_agent execution_agent
			end
		    end
		end
	    end

	    add_execution_agent(agent)
        end

    end
    
    # Add a suitable execution agent to +task+ if its model has a execution
    # agent model (see ModelLevelExecutionAgent), either by reusing one
    # that is already in the plan, or by creating a new one.
    def ExecutionAgent.spawn(task)
	agent_model = task.model.execution_agent
	candidates = task.plan.find_tasks.
	    with_model(agent_model).
	    self_owned.
	    not_finished

	agent = nil

	if candidates.empty?
	    Roby::Propagation.gather_exceptions(agent_model) do
		agent = agent_model.new
		agent.on(:stop) do
		    agent.each_executed_task do |task|
			if task.running?
			    task.emit(:aborted, "execution agent #{self} failed") 
			elsif task.pending?
			    task.remove_execution_agent agent
			    spawn(task)
			end
		    end
		end
	    end
	else
	    running, pending = candidates.partition { |t| t.running? }
	    agent = if running.empty? then pending.first
		    else running.first
		    end
	end
	task.executed_by agent
	agent
    end

    # This module is hooked in Roby::TaskEventGenerator to check that a task
    # which is being started has a suitable execution agent, and to start it if
    # it's not the case
    module ExecutionAgentStart
	def calling(context)
	    super if defined? super
	    return unless symbol == :start
	    return unless agent = task.execution_agent

	    if agent.finished? || agent.finishing?
		raise Roby::TaskModelViolation.new(task), "task #{task} has an execution agent but it is dead"
	    elsif !agent.event(:ready).happened? && !agent.depends_on?(task)
		postpone(agent.event(:ready), "spawning execution agent #{agent} for #{self}") do
		    if agent.pending?
			agent.event(:ready).if_unreachable(true) do |reason|
			    self.emit_failed "execution agent #{agent} failed to initialize: #{reason}"
			end
			agent.start!
		    end
		end
	    end
	end
    end
    Roby::TaskEventGenerator.include ExecutionAgentStart

    # This module is included in Roby::Plan to automatically add execution agents
    # to tasks that require it and are discovered in the executable plan.
    module ExecutionAgentSpawn
	# Hook into plan discovery to add execution agents to new tasks. 
	# See ExecutionAgentSpawn.spawn
	def discovered_tasks(tasks)
	    # For now, settle on adding the execution agents only in the
	    # main plan. Otherwise, it is possible that two transactions
	    # will try to add two different agents
	    #
	    # Note that it would be solved by plan merging ...
	    return unless executable?

	    for task in tasks
		if !task.execution_agent && task.model.execution_agent && task.self_owned?
		    ExecutionAgent.spawn(task)
		end
	    end
	end
    end
    Roby::Plan.include ExecutionAgentSpawn
end

