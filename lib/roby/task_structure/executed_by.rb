# frozen_string_literal: true

module Roby
    module TaskStructure # :nodoc:
        # The execution_agent defines an agent (process or otherwise) a given
        # task is executed by. It allows to define a class of these execution agent,
        # so that the specific agents are managed externally (load-balancing, ...)
        relation :ExecutionAgent,
                 parent_name: :executed_task,
                 child_name: :execution_agent,
                 noinfo: true,
                 distribute: false,
                 single_child: true,
                 copy_on_replace: true,
                 strong: true

        class ExecutedTaskAlreadyRunning < RuntimeError; end

        # Graph class for the execution agent relation
        class ExecutionAgent
            def self.execution_agent_failed_to_start(reason, ready_event)
                execution_agent = ready_event.task

                tasks = execution_agent.each_executed_task.to_a

                plan = execution_agent.plan
                plan.control.execution_agent_failed_to_start(
                    execution_agent, tasks, reason
                )
            end

            def self.pending_execution_agent_failed(event)
                execution_agent = event.task
                return unless execution_agent.ready?

                tasks = execution_agent.each_executed_task.find_all do |task|
                    task.pending? || task.starting?
                end
                return if tasks.empty?

                plan = execution_agent.plan
                plan.control.pending_executed_by_failed(execution_agent, tasks)
            end

            def self.remove_agent_aborted_relation(stop_event)
                executed_task = stop_event.task

                # The event handler will be called even if the
                # execution agent has been removed. Check that there is
                # actually an execution agent
                return unless (execution_agent = executed_task.execution_agent)

                execution_agent.stop_event.remove_forwarding executed_task.aborted_event
                executed_task.remove_execution_agent execution_agent
            end

            def self.establish_agent_aborted_relation(event)
                executed_task = event.task
                return unless (execution_agent = executed_task.execution_agent)

                # The event handler will be called even if the
                # execution agent has been removed. Check that there is
                # actually an execution agent
                execution_agent.stop_event.forward_to executed_task.aborted_event
            end

            # This module defines model-level definition of execution agent, for
            # instance to Roby::Task
            module ModelExtension
                # The model of execution agent for this class
                def execution_agent
                    ancestors.each do |klass|
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
                #          create a new one>
                #   task.executed_by exec
                #
                # for all instances of TaskModel. The actual job is done in the
                # ExecutionAgentSpawn module
                def executed_by(agent_model, arguments = {})
                    @execution_agent = [agent_model, arguments]
                end
            end

            # Module mixed-in {Roby::Task} in support for execution agent handling
            module Extension
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
                    agent = agent.as_plan if agent.respond_to?(:as_plan)
                    return if execution_agent == agent

                    unless agent.has_event?(:ready)
                        raise ArgumentError,
                              "execution agent tasks should define the :ready event"
                    end

                    # Remove the current agent if there is one
                    remove_execution_agent execution_agent if execution_agent

                    add_execution_agent(agent)
                    agent
                end

                def adding_execution_agent(child, info)
                    if running?
                        raise ExecutedTaskAlreadyRunning,
                              "#{self} is already running, cannot add or change its agent"
                    end

                    super

                    return unless (model_agent = model.execution_agent)
                    return if child.fullfills?(*model_agent)

                    raise Roby::ModelViolation,
                          "execution agent #{child} does not fullfill " \
                          "the expected #{model_agent}"
                end

                # Installs the handlers needed for fault handling
                #
                # See the documentation of #used_with_an_execution_agent?
                def added_execution_agent(child, info)
                    super

                    setup_as_executed_task_if_needed
                    child.setup_as_execution_agent_if_needed

                    nil
                end

                def setup_as_executed_task_if_needed
                    return if used_with_an_execution_agent?

                    start_event.on(
                        &ExecutionAgent.method(:establish_agent_aborted_relation)
                    )
                    stop_event.on(
                        &ExecutionAgent.method(:remove_agent_aborted_relation)
                    )
                    self.used_with_an_execution_agent = true
                end

                def setup_as_execution_agent_if_needed
                    return if used_as_execution_agent?

                    unless ready_event.emitted?
                        ready_event.when_unreachable(
                            true,
                            &ExecutionAgent.method(:execution_agent_failed_to_start)
                        )
                    end
                    stop_event.on(
                        &ExecutionAgent.method(:pending_execution_agent_failed)
                    )
                    self.used_as_execution_agent = true
                end
            end
        end

        # Exception raised when trying to start a task that requires an agent
        # but has none
        class MissingRequiredExecutionAgent < Roby::CommandFailed
            def initialize(task)
                super(nil, task.start_event)
            end

            def pretty_print(pp)
                pp.text "attempted to start a task that is " \
                        "expecting an execution agent but has none"
                pp.breakable
                failed_task.pretty_print(pp)
            end
        end

        # Exception raised when trying to start a task whose execution agent is not ready
        class ExecutionAgentNotReady < Roby::CommandFailed
            attr_reader :execution_agent

            def initialize(task)
                super(nil, task.start_event)
                @execution_agent = task.execution_agent
            end

            def pretty_print(pp)
                pp.text "attempted to start a task buts its agent is not ready"
                pp.breakable
                failed_task.pretty_print(pp)
                pp.breakable
                pp.text "executed_by "
                execution_agent.pretty_print(pp)
            end
        end

        # @api private
        #
        # This module is hooked in Roby::TaskEventGenerator to check that a task
        # which is being started has a suitable execution agent, and to start it if
        # it's not the case
        module ExecutionAgentStart
            # Helper module that installs {ExecutionAgentStart} on start events
            module Installer
                def initialize_events
                    super
                    start_event.extend ExecutionAgentStart
                end
            end

            Roby::Task.class_eval do
                prepend Installer
            end

            def calling(context)
                super

                agent = task.execution_agent
                return if agent&.ready?

                if agent
                    raise ExecutionAgentNotReady.new(task),
                          "cannot start #{task}, its agent is not ready"
                elsif task.model.execution_agent
                    raise MissingRequiredExecutionAgent.new(task),
                          "the model of #{task} requires an execution agent, " \
                          "but the task has none"
                end
            end
        end
    end
end
