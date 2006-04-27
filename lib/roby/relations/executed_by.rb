require 'roby/task'
require 'roby/relations/hierarchy'

module Roby::TaskStructure
    relation :execution_agent do
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
	    if old = execution_agent && old != agent
		Roby.debug "an agent is already defined for this task"
		remove_execution_agent old
		event(:start).remove_ensured_event old.event(:start)
	    end

	    add_execution_agent(agent)
	    event(:start).add_ensured_event(agent.event(:start))
        end

	module EventModel
	    def calling(context)
		super if defined? super
		return unless respond_to?(:task)
		return unless agent_model = task.class.execution_agent

		if agent = (task.execution_agent || Roby::Task[agent_model].to_a.first)
		    task.executed_by agent

		    if agent.finished?
			raise TaskModelViolation.new(task), "in #{self}: execution agent #{agent} is dead"
		    elsif !agent.running?
			postpone(agent.event(:ready), "spawning execution agent #{agent} for #{self}") do
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


