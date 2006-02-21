require 'roby/task'
require 'roby/event_loop'

module Roby
    # An empty task which should be planned by a 
    # planning task (the planning task can be retrieved
    # using #planning_task)
    #
    # The goal of the Roby supervisor is to make sure that 
    # the task is planned *before* it is needed. In this case,
    # the PlannedTask is replaced by the generated plan, et voila.
    #
    # Otherwise, the planned task starts the planner, inserts
    # the new plan in its task subtree and starts it
    # 
    class PlannedTask < Roby::Task
        def start(context)
            planner = planning_task
            realized_by planner, :fails_on => :failed

            planner.
                event(:start).ever.on { emit :start }.
                on(:done) { |event| 
                    emit :ready

                    plan = event.context
                    realized_by(plan)
                    plan.start!
                }
            planner.start! unless planner.running?
        end
        event :start

        event :ready    # called when the task has been successfully planned
        event :no_plan, :terminal => true  # no plan has been found
        event :stop
    end

    # An asynchronous planning task using Ruby threads
    class PlanningTask < Roby::Task
        attr_reader :plan_model, :plan_method
        def initialize(model, method)
            @plan_model, @plan_method = model, method
            
            task = PlannedTask.new
            task.extend TaskStructure::PlannedBy
            task.planned_by self

            super()
        end

        @planning_tasks = Array.new
        class << self
            attr_reader :planning_tasks
        end

        Roby.event_processing << lambda do 
            planning_tasks.each do |task|
                unless task.thread.alive?
                    if task[:plan]
                        task.emit(:found, task[:plan])
                    else
                        task.emit(:failed)
                    end
                end
            end
        end

        attr_reader :thread
        def start(context)
            on(:stop) { 
                @thread = nil 
                self.class.planning_tasks.delete(self)
            }
            self.class.planning_tasks << self
            @thread = Thread.new do
                Thread[:plan] = @plan_model.new.send(@plan_method)
            end
            emit :start
        end
        event :start

        event :failed, :terminal => true
        event :found, :terminal => true

        def stop(context); @thread.kill end
        event :stop
    end
end

