require 'roby/task'
require 'roby/relations/hierarchy'

module Roby::TaskStructure
    # The execution_agent defines an agent (process or otherwise) a given
    # task is executed by. It allows to define a class of these execution agent,
    # so that the specific agents are managed externally (load-balacing, ...)
    relation :ExecutionAgent, :parent_name => :executed_agent, :noinfo => true do
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

	    old_agent = execution_agent
	    if old_agent && old_agent != agent
		Roby.debug "an agent is already defined for this task"
		remove_execution_agent old_agent
	    end

	    add_execution_agent(agent)
        end

	module EventModel
	    def calling(context)
		super if defined? super
		return unless respond_to?(:task) && symbol == :start

		unless agent = task.execution_agent
		    unless agent_model = task.class.execution_agent
			# There is no need for an execution agent
			return
		    end

		    # Try to find an already existing agent
		    unless agent = Roby::Task.enum_for(:each_task, agent_model).find { |t| !t.finished? }
			# ... or create a new one
			begin
			    agent = agent_model.new
			rescue Exception => e
			    raise Roby::TaskModelViolation.new(task), "the #{self} model defines an execution agent, but #{agent_model}::new raised #{e.message}(#{e.class})", e.backtrace
			end
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
			agent.start!
		    end
		end

		task.event(:start).on do
		    agent.event(:stop).
			until(task.event(:stop)).
			on { |stopped| task.event(:aborted).emit(stopped.context) }
		end
	    end
	end
	Roby::EventGenerator.include EventModel
    end

    Hierarchy.superset_of ExecutionAgent
end


