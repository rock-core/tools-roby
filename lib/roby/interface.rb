require 'thread'
require 'roby'
require 'roby/planning'
require 'facet/basicobject'
require 'utilrb/column_formatter'
require 'stringio'

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

	    def __history__(history)
		history = history.map do |ev|
		    { 'Name' => ev.symbol, 'At' => ev.time }
		end
		io = StringIO.new
		ColumnFormatter.from_hashes(history, io) do
		    %w{Name At}
		end
		"\n#{io.string}"
	    end

	    def call(m, *args)
		@calling = true
		method_missing(m, *args)

	    ensure
		@calling = false
	    end

	    def method_missing(m, *args)
		v = @interface.call(@remote_id, m, *args)
		if respond_to?("__#{m}__") && !@calling
		    object_self.send("__#{m}__", v)
		else
		    v
		end
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

	def instance_methods(include_super = false)
	    Interface.instance_methods(false).
		actions.map { |name| "#{name}!" }
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
	module GatherExceptions
	    attr_accessor :control_interface
	    def fatal_exception(error, tasks)
		super if defined? super

		if control_interface
		    msg = "Fatal exception: #{error.exception.message}:\n"
		    msg << tasks.map { |t| t.to_s }.join("\n")
		    msg << "\nThe following tasks have been killed:\n"
		    tasks.each { |t| msg << "  * " << t.to_s }
		    control_interface.pending_messages << msg
		end
	    end
	end

	attr_reader :control
	attr_reader :pending_messages
	def initialize(control)
	    @control	      = control
	    @pending_messages = []

	    Roby::Control.extend GatherExceptions
	    Roby::Control.control_interface = self
	end

	# Make the Roby event loop quit
	def stop
	    control.quit 
	end
	def plan; Roby.plan end

	def call(task, m, *args)
	    Roby.execute do
		task.local_object.send(m, *args)
	    end
	end

	def find_tasks
	    plan.find_tasks
	end

	def remote_query_result_set(m_query)
	    plan.query_result_set(m_query.to_query(plan)).
		map { |t| t.remote_id }
	end

	def remote_constant(name)
	    DRbObject.new(name.to_s.constantize)
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
		flatten.
		sort
	end

	def task_set_to_s(task_set)
	    if task_set.empty?
		return "no tasks"
	    end

	    task = task_set.map do |task|
		state_name = %w{pending starting running finishing finished}.find do |state_name|
		    task.send("#{state_name}?")
		end

		start_event = task.history.find { |ev| ev.symbol == :start }
		{ 'Task' => task.to_s, 'Since' => start_event.time, 'State' => state_name }
	    end

	    io = StringIO.new
	    ColumnFormatter.from_hashes(task, io) { %w{Task Since State} }
	    "\n#{io.string}"
	end

	def running_tasks
	    Roby.execute do
		task_set_to_s(Roby.plan.find_tasks.running.to_a)
	    end
	end

	def missions
	    Roby.execute do
		task_set_to_s(control.plan.missions)
	    end
	end

	def tasks
	    Roby.execute do 
		task_set_to_s(Roby.plan.known_tasks)
	    end
	end

	def methods
	    result = super
	    result + actions.map { |n| "#{n}!" }
	end

	def poll_messages
	    Roby.execute do
		@pending_messages, messages = [], @pending_messages
		messages
	    end
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

	    if returns_model.kind_of?(TaskModelTag)
		task = Roby::Task.new
		task.extend returns_model
	    else
		# Create an abstract task which will be planned
		task = returns_model.new
	    end

	    planner = PlanningTask.new(:planner_model => planner_model, :method_name => name, :method_options => options)
	    task.planned_by planner

	    Roby.execute do
		control.plan.insert(task)
		yield(planner, task) if block_given?
	    end

	    nil
	end
    end


end


