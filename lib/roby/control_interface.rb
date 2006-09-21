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
	    planner = control.planners.find do |planner|
		planner.has_method?(name)
	    end
	    super if !planner
	    if args.size > 1
		raise ArgumentError, "wrong number of arguments (#{args.size} for 1) in `#{planner}##{name}'"
	    end
	    options = args.first || {}

	    m = planner.method_model(name, options)
	    task = (m.returns.new if m) || Task.new
	    planner = PlanningTask.new(planner, name, options)
	    task.planned_by planner

	    control.plan.insert(task)
	    yield(planner) if block_given?

	    planner.start!(nil)
	    planner
	end
    end
end


