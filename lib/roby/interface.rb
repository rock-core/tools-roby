require 'thread'
require 'roby'
require 'roby/planning'
require 'facet/basicobject'
require 'utilrb/column_formatter'
require 'stringio'
require 'roby/robot'

module Robot
    def self.prepare_action(name, arguments)
	control = Roby.control

	# Check if +name+ is a planner method, and in that case
	# add a planning method for it and plan it
	planner_model = control.planners.find do |planner_model|
	    planner_model.has_method?(name)
	end
	if !planner_model
	    raise ArgumentError, "no such planning method #{name}"
	end

	m = planner_model.model_of(name, arguments)

	# HACK: m.returns should not be nil, but it sometimes happen
	returns_model = (m.returns if m && m.returns) || Task

	if returns_model.kind_of?(Roby::TaskModelTag)
	    task = Roby::Task.new
	    task.extend returns_model
	else
	    # Create an abstract task which will be planned
	    task = returns_model.new
	end

	planner = Roby::PlanningTask.new(:planner_model => planner_model, :method_name => name, :method_options => arguments)
	task.planned_by planner
	return task, planner
    end

    def self.method_missing(name, *args)
	if name.to_s =~ /!$/
	    name = $`.to_sym
	else
	    super
	end

	if args.size > 1
	    raise ArgumentError, "wrong number of arguments (#{args.size} for 1) in #{name}!"
	end

	options = args.first || {}
	task, planner = Robot.prepare_action(name, options)
	Roby.control.plan.insert(task)

	return task, planner
    end
end

module Roby
    class RemoteObjectProxy < DRbObject
	attr_accessor :remote_interface

	def to_s; __method_missing__(:to_s) end
	def pretty_print(pp)
	    pp.text to_s
	end

	def self._load(str)
	    drb_unmarshalled = super
	    if drb_unmarshalled.kind_of?(DRbObject)
		it = self.allocate
		it.instance_variable_set('@uri', drb_unmarshalled.instance_variable_get(:@uri))
		it.instance_variable_set('@ref', drb_unmarshalled.instance_variable_get(:@ref))
		it
	    else
		drb_unmarshalled
	    end
	rescue Exception => e
	    STDERR.puts e.full_message
	end

	alias __method_missing__ method_missing
	def method_missing(*args, &block)
	    if remote_interface
		remote_interface.call(self, *args, &block)
	    else
		super
	    end
	end
    end

    class RemoteInterface
	def initialize(interface)
	    @interface = interface
	end

	def find_tasks
	    Query.new(self)
	end

	def query_result_set(query)
	    @interface.remote_query_result_set(Distributed.format(query)).each do |t|
		t.remote_interface = self
	    end
	end
	def query_each(result_set)
	    result_set.each do |t|
		yield(t)
	    end
	end
	def query_roots(result_set, relation)
	    @interface.remote_query_roots(result_set, Distributed.format(relation)).each do |t|
		t.remote_interface = self
	    end
	end

	def state
	    remote_constant('State')
	end

	def instance_methods(include_super = false)
	    Interface.instance_methods(false).
		actions.map { |name| "#{name}!" }
	end
	    

	def method_missing(m, *args)
	    result = @interface.send(m, *args)
	    if result.kind_of?(RemoteObjectProxy)
		result.remote_interface = @interface
	    end
	    result

	rescue Exception => e
	    raise e, e.message, Roby.filter_backtrace(e.backtrace)
	end
    end

    # This class is used to interface with the Roby event loop and plan. It is the
    # main front object when accessing a Roby core remotely
    class Interface
	module GatherExceptions
	    attribute(:interfaces) { Array.new }
	    def register_interface(iface)
		Roby::Control.synchronize do
		    interfaces << iface
		end
	    end 

	    def push_exception_message(name, error, tasks)
		Roby::Control.synchronize do
		    msg = "#{name}: #{error.exception.message}:\n"
		    msg << tasks.map { |t| t.to_s }.join("\n")
		    msg << "\n  #{error.exception.backtrace.join("\n  ")}" if error.exception.backtrace
		    msg << "\nThe following tasks have been killed:"
		    tasks.each { |t| msg << "\n  * " << t.to_s }

		    interfaces.each do |iface|
			iface.pending_messages << msg
		    end
		end
	    end

	    def handled_exception(error, task)
		super if defined? super
		push_exception_message("exception", error, [task])
	    end

	    def fatal_exception(error, tasks)
		super if defined? super
		push_exception_message("fatal exception", error, tasks)
	    end
	end

	attr_reader :control
	attr_reader :pending_messages
	def initialize(control)
	    @control	      = control
	    @pending_messages = Queue.new

	    Roby::Control.extend GatherExceptions
	    Roby::Control.register_interface self
	end

	# Clear the current plan
	def clear
	    Roby.execute do
		plan.missions.dup.each  { |t| plan.discard(t) }
		plan.keepalive.dup.each { |t| plan.auto(t) }
	    end
	end

	# Make the Roby event loop quit
	def stop; control.quit end
	# The Roby plan
	def plan; Roby.plan end

	def call(task, m, *args)
	    Roby.execute do
		task.send(m, *args)
	    end
	end

	def find_tasks
	    plan.find_tasks
	end

	def remote_query_result_set(m_query)
	    plan.query_result_set(m_query.to_query(plan)).
		map { |t| RemoteObjectProxy.new(t) }
	end
	def remote_query_roots(result_set, m_relation)
	    plan.query_roots(result_set, m_relation.proxy(nil)).
		map { |t| RemoteObjectProxy.new(t) }
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
	    result = []
	    while !pending_messages.empty?
		msg = pending_messages.pop
		result << msg
	    end
	    result
	end

	# Tries to find a planner method which matches +name+ with +args+. If it finds
	# one, creates a task planned by a planning task and yields both
	def method_missing(name, *args)
	    if name.to_s =~ /!$/
		name = $`.to_sym
	    else
		super
	    end

	    if args.size > 1
		raise ArgumentError, "wrong number of arguments (#{args.size} for 1) in #{name}!"
	    end

	    options = args.first || {}
	    task, planner = Robot.prepare_action(name, options)
	    begin
		Roby.wait_until(planner.event(:success)) do
		    control.plan.insert(task)
		    yield(task, planner) if block_given?
		end
	    rescue Roby::UnreachableEvent
		raise RuntimeError, "cannot start #{name}: #{planner.terminal_event.context.first}"
	    end

	    RemoteObjectProxy.new(planner.planned_task)
	end
    end
end


