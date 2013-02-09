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
	def executed_by(agent_model, arguments = Hash.new)
            options, arguments = Kernel.filter_options arguments,
                :respawn => false

	    @execution_agent = [agent_model, arguments, options]
	end
    end

    # The execution_agent defines an agent (process or otherwise) a given
    # task is executed by. It allows to define a class of these execution agent,
    # so that the specific agents are managed externally (load-balancing, ...)
    relation :ExecutionAgent, :parent_name => :executed_task, :child_name => :execution_agent, 
	:noinfo => true, :distribute => false, :single_child => true, :copy_on_replace => true do

	# When ExecutionAgent support is included in a model (for instance Roby::Task), add
	# the model-level classes  
        def self.included(klass) # :nodoc:
	    klass.extend Roby::TaskStructure::ModelLevelExecutionAgent
            super
        end

        # In order to handle faults, it is needed that some event handlers are
        # defined on the task that has an execution agent
        #
        # However, we only want to define them once. Therefore, this flag is set
        # to true as soon as the handlers have been added on +self+
        attr_predicate :used_with_an_execution_agent?, true

        # In order to handle faults, it is needed that some event handlers are
        # defined on the agent's task
        #
        # However, we only want to define them once. Therefore, this flag is set
        # to true as soon as the handlers have been added on +self+
        attr_predicate :used_as_execution_agent?, true

	# Defines a new execution agent for this task.
        def executed_by(agent, options = Hash.new)
            if agent.respond_to?(:as_plan)
                agent = agent.as_plan
            end
            options = Kernel.validate_options options, :respawn => false

	    return if execution_agent == agent

	    if !agent.event(:start).controlable? && !agent.running?
		raise ArgumentError, "the start event of #{self}'s execution agent #{agent} is not controlable"
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

	    add_execution_agent(agent, options)
            agent
        end


        # Installs the handlers needed for fault handling
        #
        # See the documentation of #used_with_an_execution_agent?
        def added_parent_object(parent, relations, info)
            super if defined? super
            return if !relations.include?(ExecutionAgent)
            return if used_as_execution_agent?

            ready_event.when_unreachable(true, &ExecutionAgentGraphClass.method(:execution_agent_failed_to_start))
            on :stop, &ExecutionAgentGraphClass.method(:pending_execution_agent_failed)

            self.used_as_execution_agent = true
        end
        
        # Installs the handlers needed for fault handling
        #
        # See the documentation of #used_with_an_execution_agent?
	def added_child_object(child, relations, info)
            super if defined? super
            return if !relations.include?(ExecutionAgent)
            return if used_with_an_execution_agent?

            start_event.extend ExecutionAgentStart

            if running?
                # Relations related to execution agents are not distributed.
                # Make Roby::Distributed ignore the following changes
                Roby::Distributed.update(self) do
                    execution_agent.forward_to(:stop, self, :aborted)
                end
            end

            on :start, &ExecutionAgentGraphClass.method(:establish_agent_aborted_relation)
            on :stop, &ExecutionAgentGraphClass.method(:remove_agent_aborted_relation)
            self.used_with_an_execution_agent = true
        end
    end

    class ExecutionAgentSpawningFailed < Roby::LocalizedError
	attr_reader :agent_model, :error
	def initialize(task, agent_model, error)
	    super(task)
	    @agent_model, @error = agent_model, error
	end
    end

    class ExecutionAgentGraphClass
        def self.execution_agent_failed_to_start(reason, ready_event)
            execution_agent = ready_event.task

            tasks = []
            execution_agent.each_executed_task do |task|
                tasks << task
            end

            plan = execution_agent.plan
            if !tasks.empty? && plan.engine
                plan.control.execution_agent_failed_to_start(execution_agent, tasks)
            end
        end

        def self.pending_execution_agent_failed(event)
            execution_agent = event.task

            if execution_agent.ready?
                tasks = []
                execution_agent.each_executed_task do |task|
                    tasks << task if task.pending? || task.starting?
                end
                
                plan = execution_agent.plan
                if !tasks.empty? && plan.engine
                    plan.control.pending_executed_by_failed(execution_agent, tasks)
                end
            end
        end

        def self.remove_agent_aborted_relation(ev)
            executed_task = ev.task
            execution_agent = executed_task.execution_agent

            # The event handler will be called even if the
            # execution agent has been removed. Check that there is
            # actually an execution agent 
            if execution_agent
                # Relations related to execution agents are not distributed.
                # Make Roby::Distributed ignore the following changes
                Roby::Distributed.update(self) do
                    execution_agent.stop_event.remove_forwarding executed_task.aborted_event
                    executed_task.remove_execution_agent execution_agent
                end
            end
        end


        def self.establish_agent_aborted_relation(ev)
            executed_task = ev.task
            execution_agent = executed_task.execution_agent

            # The event handler will be called even if the
            # execution agent has been removed. Check that there is
            # actually an execution agent 
            if execution_agent
                # Relations related to execution agents are not
                # distributed.  Make Roby::Distributed ignore the
                # following changes
                Roby::Distributed.update(self) do
                    execution_agent.forward_to(:stop, executed_task, :aborted)
                end
            end
        end
    end
    
    # Add a suitable execution agent to +task+ if its model has a execution
    # agent model (see ModelLevelExecutionAgent), either by reusing one
    # that is already in the plan, or by creating a new one.
    def ExecutionAgent.spawn(task)
	agent_model, arguments, options = task.model.execution_agent
	candidates = task.plan.find_tasks.
	    with_model(agent_model).
            with_arguments(arguments).
	    self_owned.
	    not_finished

	agent = nil

	if candidates.empty?
	    begin
		agent = agent_model.new(arguments)
		agent.on(:stop) do |ev|
                    respawn = []
		    agent.each_executed_task do |task|
                        info = task[agent, Roby::TaskStructure::ExecutionAgent]
			if task.running?
			    task.emit(:aborted, "execution agent #{self} failed") 
			elsif info[:respawn] && task.pending?
                            respawn << task
			end
		    end
                    for task in respawn
                        task.remove_execution_agent agent
                        spawn(task)
                    end
		end
	    rescue Exception => e
		task.plan.engine.add_error(ExecutionAgentSpawningFailed.new(task, agent_model, e))
	    end
	else
	    running, pending = candidates.partition { |t| t.running? }
	    agent = if running.empty? then pending.first
		    else running.first
		    end
	end
	task.executed_by agent, options
	agent
    end

    # This module is hooked in Roby::TaskEventGenerator to check that a task
    # which is being started has a suitable execution agent, and to start it if
    # it's not the case
    module ExecutionAgentStart
	def calling(context)
	    super if defined? super

            agent = task.execution_agent
            if !agent
                if task.model.execution_agent
                    raise Roby::CommandFailed.new(nil, self), "the model of #{task} requires an execution agent, but the task has none"
                else
                    return
                end
            end

            # Check that the agent matches the model
            agent_model, arguments = task.model.execution_agent
            if agent_model
                if !agent.fullfills?(agent_model, arguments)
                    raise Roby::CommandFailed.new(nil, self), "the execution agent #{agent} does not match the required model #{agent_model}, #{arguments}"
                end
            end

	    if agent.finished? || agent.finishing?
		raise Roby::CommandFailed.new(nil, self), "task #{task} has an execution agent but it is dead"
	    elsif !agent.event(:ready).happened? && !agent.depends_on?(task)
		postpone(agent.event(:ready), "spawning execution agent #{agent} for #{self}") do
		    if agent.pending?
			agent.start!
		    end
		end
	    end
	end
    end

    # This module is included in Roby::Plan to automatically add execution agents
    # to tasks that require it and are discovered in the executable plan.
    module ExecutionAgentSpawn
	# Hook into plan discovery to add execution agents to new tasks. 
	# See ExecutionAgentSpawn.spawn
	def added_tasks(tasks)
            super if defined? super
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

