require 'roby/task'
require 'roby/relations/hierarchy'

module Roby::TaskStructure
    # The execution_agent defines an agent (process or otherwise) a given
    # task is executed by. It allows to define a class of these execution agent,
    # so that the specific agents are managed externally (load-balacing, ...)
    relation :execution_agent do
	parent_enumerator :executed_agent

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

	def execution_agent; enum_for(:each_execution_agent).find { true } end
        def executed_by(agent)
	    return if execution_agent == agent
	    if !agent.event(:start).controlable?
		raise TaskModelViolation.new(self), "the start event of #{self}'s execution agent #{agent} is not controlable"
	    end
	    
	    # Check that agent defines the :ready event
	    if !agent.has_event?(:ready)
		raise ArgumentError, "execution agent tasks should define the :ready event"
	    end

	    if old = execution_agent && old != agent
		Roby.debug "an agent is already defined for this task"
		remove_execution_agent old
		agent.event(:stop).remove_causal_link event(:stop)
	    end


	    add_execution_agent(agent)
	    event(:start).on do
	        agent.event(:stop).
	            until(event(:stop)).
	            on { |event| event(:aborted).emit(event.context) }
	    end
        end

	module EventModel
	    def calling(context)
		super if defined? super
		return unless respond_to?(:task) && symbol == :start

		unless agent = task.execution_agent
		    unless agent_model = task.class.execution_agent
			return
		    end

		    all_agents = Roby::Task[agent_model].to_a
		    agent = if all_agents.empty?
				agent_model.new rescue nil
			    else
				all_agents.find { |t| !t.finished? }
			    end
		end

		if agent
		    task.executed_by agent unless task.execution_agent == agent

		    if !agent.running?
			postpone(agent.event(:ready), "spawning execution agent #{agent} for #{self}") do
			    agent.event(:start).on do
				agent.event(:stop).until(agent.event(:ready)).on do |event|
				    self.emit_failed "execution agent #{agent} failed to initialize\n  #{event.context}"
				end
			    end
			    agent.start!
			end
		    end
		else
		    raise Roby::TaskModelViolation.new(task), "the #{self} model defines an execution agent, but the task has none"
		end
	    end
	end
	Roby::EventGenerator.include EventModel
    end

    Hierarchy.superset_of ExecutionAgents
end


