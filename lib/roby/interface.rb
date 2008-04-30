require 'thread'
require 'roby'
require 'roby/planning'
require 'facets/basicobject'
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
    # An augmented DRbObject which allow to properly interface with remotely
    # running plan objects.
    class RemoteObjectProxy < DRbObject
	attr_accessor :remote_interface

	def to_s
            __method_missing__(:to_s) 
        end
	def pretty_print(pp)
	    pp.text to_s
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

    # RemoteInterface objects are used as local representation of remote
    # interface objects.  They offer a seamless interface to a remotely running
    # Roby controller.
    class RemoteInterface
        # Create a RemoteInterface object for the remote object represented by
        # +interface+, where +interface+ is a DRbObject for a remote Interface
        # object.
	def initialize(interface)
	    @interface = interface
	end

        # Returns a Query object which can be used to interactively query the
        # running plan
	def find_tasks(model = nil, args = nil)
	    q = Query.new(self)
	    if model
		q.which_fullfills(model, args)
	    end
	    q
	end

        # Defined for remotes queries to work
	def query_result_set(query) # :nodoc:
	    @interface.remote_query_result_set(Distributed.format(query)).each do |t|
		t.remote_interface = self
	    end
	end
        # Defined for remotes queries to work
	def query_each(result_set) # :nodoc:
	    result_set.each do |t|
		yield(t)
	    end
	end
        # Defined for remotes queries to work
	def query_roots(result_set, relation) # :nodoc:
	    @interface.remote_query_roots(result_set, Distributed.format(relation)).each do |t|
		t.remote_interface = self
	    end
	end

        # Returns the DRbObject for the remote controller state object
	def state
	    remote_constant('State')
	end

	def instance_methods(include_super = false) # :nodoc:
	    Interface.instance_methods(false).
		actions.map { |name| "#{name}!" }
	end
	    

	def method_missing(m, *args) # :nodoc:
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
            # The set of Interface objects that have been registered to us
	    attribute(:interfaces) { Array.new }

            # Register a new Interface object so that it gets feedback information
            # from the running controller.
	    def register_interface(iface)
		Roby::Control.synchronize do
		    interfaces << iface
		end
	    end 

            # Pushes a exception message to all the already registered remote interfaces.
	    def push_exception_message(name, error, tasks)
		Roby::Control.synchronize do
                    msg = Roby.format_exception(error.exception).join("\n")
		    msg << "\nThe following tasks have been killed:\n"
		    tasks.each do |t|
                        msg << "  "
                        if error.exception.involved_plan_object?(t)
                            msg << "#{t.class}:0x#{t.address.to_s(16)}\n"
                        else
                            PP.pp(t, msg)
                        end
                    end

		    interfaces.each do |iface|
			iface.pending_messages << msg
		    end
		end
	    end

            # Pushes an exception information on all remote interfaces connected to us
	    def handled_exception(error, task)
		super if defined? super
		push_exception_message("exception", error, [task])
	    end

            # Pushes an exception information on all remote interfaces connected to us
	    def fatal_exception(error, tasks)
		super if defined? super
		push_exception_message("fatal exception", error, tasks)
	    end
	end

        # The Roby::Control object this interface is working on
	attr_reader :control
        # The set of pending messages that are to be displayed on the remote interface
	attr_reader :pending_messages
        # Creates a local server for a remote interface, acting on +control+
	def initialize(control)
	    @control	      = control
	    @pending_messages = Queue.new

	    Roby::Control.extend GatherExceptions
	    Roby::Control.register_interface self
	end

	# Clear the current plan: remove all running and permanent tasks.
	def clear
	    Roby.execute do
		plan.missions.dup.each  { |t| plan.discard(t) }
		plan.keepalive.dup.each { |t| plan.auto(t) }
	    end
	end

	# Make the Roby event loop quit
	def stop; control.quit; nil end
	# The Roby plan
	def plan; Roby.plan end

        # Synchronously call +m+ on +tasks+ with the given arguments. This,
        # along with the implementation of RemoteInterface#method_missing,
        # ensures that no interactive operations are performed outside the
        # control thread.
	def call(task, m, *args)
	    Roby.execute do
                if m.to_s =~ /!$/
                    event_name = $`
                    # Check if the called event is terminal. If it is the case,
                    # discard the task before calling it, and make sure the user
                    # will get a message
                    #
                    if task.event(event_name).terminal?
                        plan.discard(task)
                        task.on(:stop) { |ev| pending_messages << "task #{ev.task} stopped by user request" }
                    else
                        task.on(event_name) { |ev| pending_messages << "done emitting #{ev.generator}" }
                    end
                end

		task.send(m, *args)
	    end
	end

	def find_tasks(model = nil, args = nil)
	    plan.find_tasks(model, args)
	end

        # For using Query on Interface objects
	def remote_query_result_set(m_query) # :nodoc:
	    plan.query_result_set(m_query.to_query(plan)).
		map { |t| RemoteObjectProxy.new(t) }
	end
        # For using Query on Interface objects
	def remote_query_roots(result_set, m_relation) # :nodoc:
	    plan.query_roots(result_set, m_relation.proxy(nil)).
		map { |t| RemoteObjectProxy.new(t) }
	end

        # Returns a DRbObject on the given named constant. Use this to get a
        # remote interface to a given object, not taking into account its
        # 'marshallability'
	def remote_constant(name)
	    DRbObject.new(name.to_s.constantize)
	end

	# Reload the Roby framework code
        #
        # WARNING: does not work for now
	def reload
	    Roby.app.reload
	    nil
	end

        # Displays the set of models as well as their superclasses
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

        # Displays the set of actions which are available through the planners
        # registered on #control. See Control#planners
	def actions
	    control.planners.
		map { |p| p.planning_methods_names.to_a }.
		flatten.
		sort
	end

        # Pretty-prints a set of tasks
	def task_set_to_s(task_set) # :nodoc:
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

        # Returns a string representing the set of running tasks
	def running_tasks
	    Roby.execute do
		task_set_to_s(Roby.plan.find_tasks.running.to_a)
	    end
	end

        # Returns a string representing the set of missions
	def missions
	    Roby.execute do
		task_set_to_s(control.plan.missions)
	    end
	end

        # Returns a string representing the set of tasks present in the plan
	def tasks
	    Roby.execute do 
		task_set_to_s(Roby.plan.known_tasks)
	    end
	end

	def methods
	    result = super
	    result + actions.map { |n| "#{n}!" }
	end

        # Called every once in a while by RemoteInterface to read and clear the
        # set of pending messages.
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


