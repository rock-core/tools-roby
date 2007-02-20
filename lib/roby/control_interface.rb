require 'thread'
require 'roby'
require 'roby/planning'
require 'facet/basicobject'

module Roby
    # This class is used to interface with the Roby event loop and plan. It is the
    # main front object when accessing a Roby core remotely
    class ControlInterface
	attr_reader :control
	private :control
	def initialize(control)
	    @control = control
	    super()
	end

	# Make the Roby event loop quit
	def quit; control.quit end

	# Tries to find a planner method which matches +name+ with +args+. If it finds
	# one, creates a task planned by a planning task and yields both
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

	    # HACK: m.returns should not be nil, but it sometimes happen
	    returns_model = (m.returns if m && m.returns) || Task.new

	    # Create an abstract task which will be planned
	    task = returns_model.new

	    planner = PlanningTask.new(:planner_model => planner_model, :method_name => name, :method_options => options)
	    task.planned_by planner
	    if do_start
		planner.on(:success, task, :start)
	    end

	    Control.once do
		control.plan.insert(task)
		yield(planner, task) if block_given?
	    end
	end
    end
end


