require 'thread'
require 'roby/control'
require 'roby/planning/task'
require 'facet/basicobject'

module Roby
    class ControlInterface
	include MonitorMixin
	class Proxy < BasicObject
	    def initialize(interface, object); @interface, @object = interface, object end
	    def method_missing(name, *args, &block)
		@interface.in_controlthread do
		    @object.send(name, *args, &block)
		end
	    end
	end

	attr_reader :control, :control_synchro
	private :control
	def initialize(control)
	    @control = control
	    @control_synchro = new_cond
	    super()
	end

	def in_controlthread
	    synchronize do
		result, error = nil
		Control.once do
		    begin
			result = yield
		    rescue Exception
			error = $!
		    end
		    synchronize { control_synchro.broadcast }
		end
		control_synchro.wait
		if error then raise error
		else result
		end
	    end
	end

	def quit; control.quit end
	def models(matching = //)
	    ObjectSpace.enum_for(:each_object, Class).
		find_all { |klass| klass < Roby::Task && matching === klass.name }.
		map { |model| DRbObject.new(model) }
	end

	def find_task_model(model)
	    if model.kind_of?(Class)
	       	if model < Roby::Task then model
		else 
		    raise TypeError, "invalid task model #{model}"
		end
	    else
		matches = models(model)
		if matches.empty?
		    raise ArgumentError, "no match for #{model}: #{matches}"
		elsif matches.size > 1
		    raise ArgumentError, "more than one match available for #{model}: #{matches}"
		end
		matches[0]
	    end
	end

	def create(task_model, arguments = {})
	    model = find_task_model(task_model)
	    Proxy.new(self, model.new(arguments))
	end

	def plan; @plan ||= Proxy.new(control.plan) end

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

	    planner = PlanningTask.new(planner_model, name, options)
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


