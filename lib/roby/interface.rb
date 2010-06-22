require 'utilrb/column_formatter'

module Roby
    # Used in the shell as a local representation of a task in the main plan
    #
    # An augmented DRbObject which allow to properly interface with remotely
    # running plan objects.
    class RemoteObjectProxy < DRbObject
        # The RemoteInterface instance we are associated with
	attr_accessor :remote_interface

	def to_s # :nodoc:
            __method_missing__(:to_s) 
        end
	def pretty_print(pp) # :nodoc:
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
            reconnect
        end

        def reconnect
            # Verify that passing objects around works fine
            obj = @interface.connection_test_object
            @interface.connection_test(obj)

            remote_models = @interface.task_models
            remote_models.map do |klass|
                klass = klass.proxy(nil)

                if klass.respond_to?(:remote_name) && klass.remote_name
                    # This is a local proxy for a remote model. Add it in our
                    # namespace as well.
                    path  = klass.remote_name.split '::'
                    klass_name = path.pop
                    mod = Object
                    while !path.empty?
                        name = path.shift
                        mod = begin
                                  mod.const_get(name)
                              rescue NameError
                                  mod.const_set(name, Module.new)
                              end
                    end
                    begin
                        mod.const_set(klass_name, klass)
                    rescue NameError => e
                        STDERR.puts "cannot map remove model #{klass_name} (#{klass}): #{e.message}"
                    end
                end
            end
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

        # Displays a summary of the available actions
        #
        # See #actions for details
        def actions_summary(with_advanced = false)
            methods = @interface.actions
            if !with_advanced
                methods = methods.delete_if { |m| m.description.advanced? }
            end

            if !methods.empty?
                puts
                desc = methods.map do |p|
                    doc = p.description.doc || ["(no description set)"]
                    Hash['Name' => "#{p.name}!", 'Description' => doc.join("\n")]
                end

                ColumnFormatter.from_hashes(desc, STDOUT,
                                            :header_delimiter => true, 
                                            :column_delimiter => "|",
                                            :order => %w{Name Description})
                puts
            end

            nil
        end

        # Displays a detailed description of available actions. If +advanced+ is
        # true (false by default), advanced actions are displayed as well.
        #
        # Actions are planning methods defined on a registered Planner class.
        # For instance:
        #
        #   class MainPlanner < Roby::Planning::Planner
        #
        #       describe("grasps the given object").
        #           arg("object", "the object name ('GLASS' or 'PLATE')")
        #       method :grasp do
        #           Grasp.new(:object => arguments[:object])
        #       end
        #   end
        def actions(with_advanced = false)
            @interface.actions.each do |m|
                next if m.description.advanced? if !with_advanced
                display_action_description(m)
                puts
            end
            nil
        end

        # Standard way to display a set of tasks
	def task_set_to_s(task_set) # :nodoc:
	    if task_set.empty?
		return "no tasks"
	    end

	    task = task_set.map do |task|
		state_name = %w{pending starting running finishing finished}.find do |state_name|
		    task.send("#{state_name}?")
		end

                kind =
                    if task.mission? then 'mission'
                    elsif plan.permanent?(task) then 'permanent'
                    else ''
                    end

                since      = task.start_time
                lifetime   = task.lifetime
		Hash['Task' => task.to_s,
                     'Kind' => kind,
                    'State' => state_name,
                    'Since' => (since.asctime if since),
                    'Lifetime' => (Time.at(lifetime).to_hms if lifetime)
                ]
	    end
            task.sort_by { |t| t['Task'] }

            io = StringIO.new
	    ColumnFormatter.from_hashes(task, STDOUT,
                    :header_delimiter => true,
                    :column_delimiter => "|",
                    :order => %w{Task State Lifetime Since})
	end
        
        # Displays information about the plan's missions
        def missions
            missions = find_tasks.mission.to_a
            task_set_to_s(missions)
            nil
        end
        
        # Displays information about the plan's missions
        def permanent_tasks
            permanent = find_tasks.permanent.to_a
            task_set_to_s(permanent)
            nil
        end

        # Displays information about the running tasks
        def running_tasks
            tasks = find_tasks.running.to_a
            task_set_to_s(tasks)
            nil
        end

        # Displays details about the actions matching 'regex'
        def describe(name, with_advanced = false)
            name = Regexp.new(name)
            m = @interface.actions.find_all { |p| name === p.name }

            if !with_advanced
                filtered = m.find_all { |m| !m.description.advanced? }
                m = filtered if !filtered.empty?
            end

            if m.empty?
                puts "no such method"
            else
                m.each do |desc|
                    puts
                    display_action_description(desc)
                    puts
                end
            end
            nil
        end

        # Displays a help message
        def help
            puts
            puts "Available Actions"
            puts "================="
            actions_summary
            puts ""


            puts <<-EOHELP
each action is started with action_name!(:arg1 => value1, :arg2 => value2, ...)
and returns the corresponding task object. A message is displayed in the shell
when the task finishes."

Shell Commands
==============
Command         | Help
---------------------------------------------------------------------------------------------
actions_summary(advanced = false) | displays the list of actions with a short documentation |
actions(advanced = false)         | displays details for each available actions             |
describe(regex)                   | displays details about the actions matching 'regex'     |
missions                          | displays the set of running missions with their status  |
running_tasks                     | displays the set of running tasks with their status     |
unmark(task)                      | remove permanent or mission mark on +task+              |
                                  |                                                         |
help                              | this help message                                       |

            EOHELP
        end

        # Standard display of an action description. +m+ is a PlanningMethod
        # object.
        def display_action_description(m) # :nodoc:
            args = m.description.arguments.
                sort_by { |arg_desc| arg_desc.name }

            first = true
            args_summary = args.map do |arg_desc|
                name        = arg_desc.name
                is_required = arg_desc.required
                format = if is_required then "%s"
                         else "[%s]"
                         end
                text = format % ["#{", " if !first}:#{name} => #{name}"]
                first = false
                text
            end

            args_table = args.
                map do |arg_desc|
                    Hash['Argument' => arg_desc.name,
                         'Description' => (arg_desc.doc || "(no description set)")]
                end

            method_doc = m.description.doc || [""]
            puts "#{m.name}! #{args_summary.join("")}\n#{method_doc.join("\n")}"
            if m.description.arguments.empty?
                puts "No arguments"
            else
                ColumnFormatter.from_hashes(args_table, STDOUT,
                                            :left_padding => "  ",
                                            :header_delimiter => true,
                                            :column_delimiter => "|",
                                            :order => %w{Argument Description})
            end
        end
    
        # Removes any permanent/mission mark on +task+, making it eligible for
        # GC
        def unmark(task)
            @interface.unmark(task)
            nil
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
        # This module defines the hooks needed to plug Interface objects onto
        # ExecutionEngine
	module GatherExceptions
            # The set of Interface objects that have been registered to us
	    attribute(:interfaces) { Array.new }

            # Register a new Interface object so that it gets feedback information
            # from the running controller.
	    def register_interface(iface)
		Roby.synchronize do
		    interfaces << iface
		end
	    end 

            # Pushes a exception message to all the already registered remote interfaces.
	    def push_exception_message(name, error, tasks)
		Roby.synchronize do
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

        # The engine this interface is tied to
        attr_reader :engine
        # The set of pending messages that are to be displayed on the remote interface
	attr_reader :pending_messages
        # Creates a local server for a remote interface, acting on +control+
	def initialize(engine)
	    @pending_messages = Queue.new
            @engine = engine

	    engine.extend GatherExceptions
	    engine.register_interface self
	end

	# Clear the current plan: remove all running and permanent tasks.
	def clear
	    engine.execute do
		plan.missions.dup.each  { |t| plan.discard(t) }
		plan.permanent_tasks.dup.each { |t| plan.auto(t) }
		plan.permanent_events.dup.each { |t| plan.auto(t) }
	    end
	end

        # Unmarks the given task
        def unmark(task)
            engine.execute do
                engine.plan.unmark_mission(task.to_task)
                engine.plan.unmark_permanent(task.to_task)
            end
        end

	# Make the Roby event loop quit
	def stop; engine.quit; nil end
	# The Roby plan
	def plan; engine.plan end

        # Synchronously call +m+ on +tasks+ with the given arguments. This,
        # along with the implementation of RemoteInterface#method_missing,
        # ensures that no interactive operations are performed outside the
        # control thread.
	def call(task, m, *args)
	    engine.execute do
                if m.to_s =~ /!$/
                    event_name = $`
                    # Check if the called event is terminal. If it is the case,
                    # discard the task before calling it, and make sure the user
                    # will get a message
                    #
                    if task.event(event_name).terminal?
                        plan.unmark_mission(task)
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

        # Returns the set of task models as DRobyTaskModel objects. The standard
        # Roby task models are excluded.
	def task_models
	    task_models = []
	    engine.execute do
		ObjectSpace.each_object(Class) do |obj|
                    if obj <= Roby::Task && obj.name !~ /^Roby::/
                        task_models << obj
                    end
		end
	    end
            task_models.map { |t| t.droby_dump(nil) }
	end

        # Returns the set of PlanningMethod objects that describe the methods
        # exported in the application's planners.
	def actions
	    Roby.app.planners.
		map do |p|
                    p.planning_methods
                end.flatten.sort_by { |p| p.name }
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

        module PlanServiceUI
            attr_accessor :shell
            attr_accessor :id
            attr_accessor :name

            def self.allocate_id; @@id += 1 end
            @@id = 0

            def task=(new_task)
                shell.pending_messages << "[#{id}] #{name}!: #{self.task} has been replaced by #{new_task}"
                super
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

	    if args.size > 1
		raise ArgumentError, "wrong number of arguments (#{args.size} for 1) in #{name}!"
	    end

	    options = args.first || {}
            shell = self
            engine.execute do
                task, planner = Robot.prepare_action(plan, name, options)

                service = PlanService.new(task)
                service.extend PlanServiceUI
                service.shell = shell
                service.id    = PlanServiceUI.allocate_id
                service.name  = name
                service.when_finalized  { shell.pending_messages << "[#{service.id}] #{name}!: task #{service.task} has been removed" }
                service.on(:start)   { |ev| shell.pending_messages << "[#{service.id}] #{name}!: task #{ev.task} started" }
                service.on(:failed)  { |ev| shell.pending_messages << "[#{service.id}] #{name}!: task #{ev.task} failed" }
                service.on(:success) { |ev| shell.pending_messages << "[#{service.id}] #{name}!: task #{ev.task} finished successfully" }

                planner.on(:failed) do |ev|
                    exception = ev.context.first
                    shell.pending_messages << "planning #{name} failed with"
                    Roby.format_exception(exception).each do |line|
                        shell.pending_messages << "  #{line}"
                    end
                end

                shell.pending_messages << "[#{service.id}] #{name}! started to plan"

                plan.add_mission(task)
                RemoteObjectProxy.new(service)
            end
	end

        def connection_test_object
            DRbObject.new(Object.new)
        end
        def connection_test(obj)
            if obj.kind_of?(DRbObject)
                raise "cannot pass remote objects in connection (#{obj.__drburi} != #{DRb.current_server.uri})"
            end
        end
    end
end


