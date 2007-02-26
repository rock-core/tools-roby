require 'roby/task'

module Roby::TaskStructure
    # The execution_agent defines an agent (process or otherwise) a given
    # task is executed by. It allows to define a class of these execution agent,
    # so that the specific agents are managed externally (load-balacing, ...)
    relation :ExecutionAgent, :parent_name => :executed_task, :noinfo => true, :distribute => false do
        def self.included(klass)
            class << klass
                attr_reader :execution_agent
                # Defines a model of execution agent
                # model.new_task(task) shall return the task instance which
                # will execute this task 
                def executed_by(agent)
                    @execution_agent = agent
                end
            end
            super
        end

	def execution_agent; child_objects(ExecutionAgent).find { true } end
        def executed_by(agent)
	    return if execution_agent == agent
	    if !agent.event(:start).controlable?
		raise TaskModelViolation.new(self), "the start event of #{self}'s execution agent #{agent} is not controlable"
	    end

	    on(:start) { agent.forward(:stop, self, :aborted) }
	    on(:stop) do 
		remove_execution_agent agent
		agent.event(:stop).remove_forwarding event(:aborted)
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
		on(:start) do
		    execution_agent.forward(:stop, self, :aborted)
		end
		on(:stop) do 
		    execution_agent.event(:stop).remove_forwarding event(:aborted)
		    remove_execution_agent execution_agent
		end
	    end

	    add_execution_agent(agent)
        end

	module EventHooks
	    def calling(context)
		super if defined? super
		return unless symbol == :start
		return unless agent = task.execution_agent

		if agent.pending?
		    postpone(agent.event(:ready), "spawning execution agent #{agent} for #{self}") do
			agent.event(:start).on do
			    agent.event(:stop).until(agent.event(:ready)).on do |event|
				self.emit_failed "execution agent #{agent} failed to initialize\n  #{event.context}"
			    end
			end
			agent.start! unless agent.event(:start).pending?
		    end
		elsif agent.finished?
		    raise Roby::TaskModelViolation.new(task), "task #{task} has an execution agent but it is dead"
		end
	    end
	end
	Roby::TaskEventGenerator.include EventHooks

	module SpawnExecutionAgents
	    def discovered_tasks(tasks)
		tasks.each do |task|
		    if !task.execution_agent && task.model.execution_agent
			ExecutionAgent.spawn(task)
		    end
		end
	    end
	end
	Roby::Plan.include SpawnExecutionAgents
    end

    def ExecutionAgent.spawn(task)
	agent_model = task.model.execution_agent
	candidates = task.plan.find_tasks.
	    with_model(agent_model).
	    local.
	    not_finished.
	    to_a

	if candidates.empty?
	    Roby::Propagation.gather_exceptions(agent_model) do
		agent = agent_model.new
		agent.on(:stop) do
		    agent.each_executed_task do |task|
			if task.running?
			    task.emit(:aborted) 
			elsif task.pending?
			    task.remove_execution_agent agent
			    spawn(task)
			end
		    end
		end
		candidates << agent
	    end
	end

	running, pending = candidates.partition { |t| t.running? }
	agent = if running.empty? then pending.first
		else running.first
		end

	task.executed_by agent
	unless agent.running?
	    task.event(:start).ensure agent.event(:start) 
	end
    end
end

