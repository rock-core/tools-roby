require 'roby/control'
require 'roby/planning/task'

module Roby
    class ControlInterface
	attr_reader :control
	def initialize(control)
	    @control = control
	end

	def quit; control.quit end

	def method_missing(name, *args)
	    # Check if +name+ is a planner method, and in that case
	    # add a planning method for it and plan it
	    planner_model = control.planners.find do |planner_model|
		planner_model.has_method?(name)
	    end
	    super if !planner_model

	    if args.size > 1
		raise ArgumentError, "wrong number of arguments (#{args.size} for 1) in `#{planner_model}##{name}'"
	    end
	    options = args.first || {}
	    do_start = options.delete(:start) || options.delete('start')

	    m = planner_model.model_of(name, options)
	    task = (m.returns.new if m) || Task.new

	    planner = PlanningTask.new(control.plan, planner_model, name, options)
	    task.planned_by planner

	    control.plan.insert(task)
	    yield(planner) if block_given?

	    if do_start
		planner.on(:success, task, :start)
	    end

	    planner
	end
    end
end


