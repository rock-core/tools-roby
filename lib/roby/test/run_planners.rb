module Roby
    module Test
        module RunPlanners
            # @api private
            #
            # Helper that sets up the planning handlers for {#run_planners}
            def self.setup_planning_handlers(plan, root_task, recursive: true)
                if root_task.respond_to?(:as_plan)
                    root_task = root_task.as_plan
                    plan.add(root_task)
                end

                if recursive
                    tasks = plan.task_relation_graph_for(Roby::TaskStructure::Dependency).
                        enum_for(:depth_first_visit, root_task).to_a
                else
                    tasks = [root_task]
                end

                by_handler = tasks.find_all { |t| t.abstract? && t.planning_task }.
                    group_by { |t| RunPlanners.planner_handler_for(t) }.
                    map { |handler_class, tasks| [handler_class.new, tasks] }
                return root_task.as_service, Array.new if by_handler.empty?

                placeholder_tasks = Hash.new
                by_handler.each do |handler, tasks|
                    tasks.each do |t|
                        placeholder_tasks[t] = t.as_service
                    end
                    handler.start(tasks)
                end

                return (placeholder_tasks[root_task] || root_task.as_service), by_handler
            end

            # Run the planners that are required by a task or subplan
            #
            # @param [Task] root_task the task whose planners we want to run, or
            #   the root of the subplan
            # @param [Boolean] recursive whether the method attempts to run the
            #   planners recursively in both plan (considering the whole subplan
            #   of root_task) and time (re-run planners for tasks if existing
            #   planning tasks generate subplans containing planning tasks
            #   themselves)
            def run_planners(root_task, recursive: true)
                if !execution_engine.in_propagation_context?
                    service = nil
                    expect_execution { service = run_planners(root_task, recursive: recursive) }.
                        to_run
                    if service
                        return service.to_task
                    else return
                    end
                end

                root_task_service, by_handler = RunPlanners.setup_planning_handlers(plan, root_task, recursive: recursive)
                return root_task_service if by_handler.empty?

                add_expectations do
                    achieve(description: "expected all planning handlers to finish") do
                        if by_handler && !by_handler.empty? && by_handler.all? { |handler, tasks| handler.finished? }
                            if recursive
                                by_handler = nil
                                execute do
                                    new_root = root_task_service.to_task
                                    root_task_service, by_handler = RunPlanners.setup_planning_handlers(plan, new_root, recursive: true)
                                end
                            else
                                by_handler = Array.new
                            end
                        end

                        # by_handler == nil is used to indicate that an execute
                        # block is pending
                        by_handler && by_handler.empty?
                    end
                end
                return root_task_service
            end

            # Interface for a planning handler for {#roby_run_planner}
            #
            # This class is only used to describe the required interface. See
            # {ActionPlanningHandler} for an example
            class PlanningHandler
                # Start planning these tasks
                #
                # This is called within a propagation context
                def start(tasks)
                    raise NotImplementedError
                end

                # Whether planning is finished for the given tasks
                #
                # This is called within a propagation context
                def finished?
                    raise NotImplementedError
                end
            end

            @@roby_planner_handlers = Array.new

            # @api private
            #
            # Find the handler that should be used by {#roby_run_planner} to
            # plan a given task.
            #
            # @param [Task] task
            # @return [PlanningHandler]
            # @raise ArgumentError
            def self.planner_handler_for(task)
                _, handler_class = @@roby_planner_handlers.find { |matcher, handler| matcher === task }
                if handler_class
                    handler_class
                else
                    raise ArgumentError, "no planning handler found for #{task}"
                end
            end

            # Declare what {#roby_run_planner} should use to develop a given
            # task during a test
            #
            # The latest handler registered wins
            #
            # @param [PlanningHandler] a planning handler
            def self.roby_plan_with(matcher, handler)
                @@roby_planner_handlers.unshift [matcher, handler]
            end


            # Planning handler for {#roby_run_planner} that handles roby action tasks
            class ActionPlanningHandler
                # (see PlanningHandler#start)
                def start(tasks)
                    @planning_tasks = tasks.map do |planned_task|
                        planning_task = planned_task.planning_task
                        execution_engine = planning_task.execution_engine
                        if !execution_engine.scheduler.enabled?
                            planning_task.start!
                        end
                        planning_task
                    end
                end
                
                # (see PlanningHandler#finished?)
                def finished?
                    @planning_tasks.all?(&:success?)
                end
            end
            roby_plan_with Roby::Task.match.with_child(Roby::Actions::Task), ActionPlanningHandler
        end
    end
end


