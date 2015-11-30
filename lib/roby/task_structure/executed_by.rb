module Roby::TaskStructure
    # The execution_agent defines an agent (process or otherwise) a given
    # task is executed by. It allows to define a class of these execution agent,
    # so that the specific agents are managed externally (load-balancing, ...)
    relation :ExecutionAgent,
        parent_name: :executed_task,
        child_name: :execution_agent,
	noinfo: true,
        distribute: false,
        single_child: true,
        copy_on_replace: true

    class ExecutionAgentSpawningFailed < Roby::LocalizedError
	attr_reader :agent_model, :error
	def initialize(task, agent_model, error)
	    super(task)
	    @agent_model, @error = agent_model, error
	end
    end

    class ExecutionAgent
        def self.execution_agent_failed_to_start(reason, ready_event)
            execution_agent = ready_event.task

            tasks = []
            execution_agent.each_executed_task do |task|
                tasks << task
            end

            plan = execution_agent.plan
            if !tasks.empty?
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
                    execution_agent.stop_event.forward_to executed_task.aborted_event
                end
            end
        end

        # This module defines model-level definition of execution agent, for
        # instance to Roby::Task
        module ModelExtension
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
                @execution_agent = [agent_model, arguments]
            end
        end

        module Extension
            def initialize_events
                super if defined? super
                start_event.extend ExecutionAgentStart
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
            def executed_by(agent)
                if agent.respond_to?(:as_plan)
                    agent = agent.as_plan
                end

                return if execution_agent == agent

                if !agent.event(:start).controlable? && !agent.running?
                    raise ArgumentError, "the start event of #{self}'s execution agent #{agent} is not controlable"
                elsif !agent.has_event?(:ready)
                    raise ArgumentError, "execution agent tasks should define the :ready event"
                end

                old_agent = execution_agent
                if old_agent && old_agent != agent
                    remove_execution_agent old_agent
                end

                add_execution_agent(agent)
                agent
            end

            def adding_execution_agent(child, info)
                super if defined? super

                if model_agent = model.execution_agent
                    if !child.fullfills?(*model_agent)
                        raise Roby::ModelViolation, "execution agent #{child} does not fullfill the expected #{model_agent}"
                    end
                end
            end

            # Installs the handlers needed for fault handling
            #
            # See the documentation of #used_with_an_execution_agent?
            def added_execution_agent(child, info)
                super if defined? super

                if !used_with_an_execution_agent?
                    if running?
                        # Relations related to execution agents are not distributed.
                        # Make Roby::Distributed ignore the following changes
                        Roby::Distributed.update(self) do
                            execution_agent.forward_to(:stop, self, :aborted)
                        end
                    else
                        start_event.on(&ExecutionAgent.method(:establish_agent_aborted_relation))
                    end

                    stop_event.on(&ExecutionAgent.method(:remove_agent_aborted_relation))
                    self.used_with_an_execution_agent = true
                end

                if !child.used_as_execution_agent?
                    child.ready_event.when_unreachable(
                        true, &ExecutionAgent.method(:execution_agent_failed_to_start))
                    child.stop_event.on(
                        &ExecutionAgent.method(:pending_execution_agent_failed))
                    child.used_as_execution_agent = true
                end
            end
        end
    end

    Roby::Task.extend ExecutionAgent::ModelExtension
    
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
	    elsif agent.finished? || agent.finishing?
		raise Roby::CommandFailed.new(nil, self), "task #{task} has an execution agent but it is dead"
	    end
	end
    end
end

