require 'roby/task'

module Roby::TaskStructure
    # The execution_agent defines an agent (process or otherwise) a given
    # task is executed by. It allows to define a class of these execution agent,
    # so that the specific agents are managed externally (load-balacing, ...)
    relation :ExecutionAgent, :parent_name => :executed_agent, :noinfo => true, :distribute => false do
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
	    
	    # Check that agent defines the :ready event
	    if !agent.has_event?(:ready)
		raise ArgumentError, "execution agent tasks should define the :ready event"
	    end

	    old_agent = execution_agent
	    if old_agent && old_agent != agent
		Roby.debug "an agent is already defined for this task"
		remove_execution_agent old_agent
	    end

	    add_execution_agent(agent)
        end

	module EventHooks
	    def calling(context)
		super if defined? super
		return unless symbol == :start

		unless agent = task.execution_agent
		    unless agent_model = task.class.execution_agent
			# There is no need for an execution agent
			return
		    end

		    # Try to find an already existing agent
		    agents = plan.known_tasks.find_all { |t| t.local? && t.kind_of?(agent_model) && !t.finished? }
		    if agents.empty?
			# ... or create a new one
			begin
			    agents = [agent_model.new]
			rescue Exception => e
			    raise Roby::TaskModelViolation.new(task), "the #{self} model defines an execution agent, but #{agent_model}::new raised #{e.full_message}"
			end
		    end

		    running_agents, pending_agents = agents.partition { |t| t.running? }
		    agent = if !running_agents.empty? then running_agents.first
			    else pending_agents.first
			    end
		    task.executed_by agent
		end

		if !agent.running?
		    postpone(agent.event(:ready), "spawning execution agent #{agent} for #{self}") do
			agent.event(:start).on do
			    agent.event(:stop).until(agent.event(:ready)).on do |event|
				self.emit_failed "execution agent #{agent} failed to initialize\n  #{event.context}"
			    end
			end
			agent.start! unless agent.event(:start).pending?
		    end
		end

		task.event(:start).on do
		    agent.event(:stop).
			until(task.event(:stop)).
			on { |stopped| task.event(:aborted).emit(stopped.context) }
		end
	    end
	
	    def fired(event)
		super if defined? super
		if task.local? && task.finished? && (agent = task.execution_agent)
		    task.remove_execution_agent agent
		end
	    end
	end
	Roby::TaskEventGenerator.include EventHooks
    end
end


