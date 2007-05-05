require 'thread'
require 'roby'
require 'roby/planning'
require 'facet/basicobject'

module Roby
    class RemoteInterface
	def initialize(interface)
	    @interface = interface
	end

	# This class wraps the RemoteID of a task. When a method is called on
	# it, the corresponding method is called on the other side, in control
	# context.
	#
	# This is used to interface a remote Task object with the user
	class TaskProxy < ::BasicObject
	    def initialize(remote_id, interface)
		@remote_id = remote_id
		@interface = interface
	    end

	    def method_missing(m, *args)
		@interface.call(@remote_id, m, *args)
	    end
	end

	def find_tasks
	    Query.new(self)
	end

	def query_result_set(query)
	    @interface.remote_query_result_set(query)
	end
	def query_each(result_set)
	    result_set.each do |t|
		yield(TaskProxy.new(t, @interface))
	    end
	end

	def method_missing(m, *args)
	    @interface.send(m, *args)

	rescue Exception => e
	    raise e, e.message, Roby.filter_backtrace(e.backtrace)
	end
    end

    # This class is used to interface with the Roby event loop and plan. It is the
    # main front object when accessing a Roby core remotely
    class Interface
	attr_reader :control
	private :control
	def initialize(control)
	    @control = control
	    super()
	end

	# Make the Roby event loop quit
	def quit
	    control.quit 
	    control.join
	end
	def plan; Roby.plan end

	def call(task, m, *args)
	    Roby.execute do
		task.local_object.send(m, *args)
	    end
	end

	def test_find_tasks
	    plan.find_tasks.to_a
	end

	def find_tasks
	    plan.find_tasks
	end

	def remote_query_result_set(m_query)
	    plan.query_result_set(m_query.to_query(plan)).
		map { |t| t.remote_id }
	end

	# Reload the Roby framework code. For now, it does not
	def reload
	    Roby.app.reload
	    nil
	end

	def models
	    task_models = []
	    Roby.execute do
		ObjectSpace.each_object(Class) do |obj|
		    task_models << obj if obj <= Roby::Task && obj.name !~ /^Roby::/
		end
	    end

	    task_models.map do |model|
		"#{model} #{model.superclass}"
	    end
	end

	def actions
	    control.planners.
		map { |p| p.planning_methods_names.to_a }.
		flatten
	end

	def task_set_to_s(task_set)
	    task_set.map do |task|
		state_name = %w{pending starting running finishing finished}.find do |state_name|
		    task.send("#{state_name}?")
		end

		[task.to_s, state_name]
	    end
	end
	def running_tasks
	    Roby.execute do
		task_set_to_s(Roby.plan.find_tasks.running.to_a)
	    end
	end

	def missions
	    missions = Roby.execute do
		task_set_to_s(control.plan.missions)
	    end
	end

	def methods
	    result = super
	    result + actions.map { |n| "#{n}!" }
	end


	# Tries to find a planner method which matches +name+ with +args+. If it finds
	# one, creates a task planned by a planning task and yields both
	def method_missing(name, *args)
	    if name.to_s =~ /!$/
		name = $`.to_sym
	    else
		super
	    end

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

	    Roby.execute do
		control.plan.insert(task)
		yield(planner, task) if block_given?
	    end

	    nil
	end
    end


end


