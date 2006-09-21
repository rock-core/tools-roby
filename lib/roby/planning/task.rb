require 'roby/task'
require 'roby/relations/planned_by'
require 'roby/control'

module Roby
    # An asynchronous planning task using Ruby threads
    class PlanningTask < Roby::Task
        attr_reader :planner, :method_name, :method_options
        def initialize(planner, method, options)
            @planner, @method_name, @method_options = planner, method, options
            super()
        end

        @planning_tasks = Array.new
        class << self
            attr_reader :planning_tasks
        end

        Control.event_processing << lambda do 
            planning_tasks.each { |task| task.poll }
        end

        attr_reader :thread, :result
        def start(context)
	    if !planned_task
		raise TaskModelViolation.new(self), "we are not planning any task"
	    end

            PlanningTask.planning_tasks << self
            @thread = Thread.new do
		@result = begin
			      @planner.send(@method_name, @method_options)
			  rescue Exception => e; e
			  end
            end
            emit(:start, context)
        end
        event :start

	def poll
	    return if thread.alive?

	    @thread = nil
	    PlanningTask.planning_tasks.delete(self)

	    case result
	    when Planning::PlanModelError
		emit(:failed, task.result)
	    when Roby::Task
		plan = planner.plan
		plan.replace(planned_task, result)
		emit(:success)
	    else
		raise "expected an exception or a Task, got #{result.inspect}"
	    end
	end

        def stop(context); thread.kill end
        event :stop
    end
end

