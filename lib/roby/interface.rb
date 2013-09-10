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

    class RemoteService < RemoteObjectProxy
        def id
            method_missing(:id)
        end
    end

    # Base class for representation, on the shell side, of a ShellInterface
    # object
    #
    # It makes sure that RemoteObjectProxy objects are properly set up when
    # received on this side
    class RemoteShellInterface
        attr_reader :interfaces

        def initialize(interface)
            @interface = interface
            @interfaces = Hash.new
        end

        class DRobyManager < Distributed::DumbManager
            def self.local_object(object)
                if object.kind_of?(RemoteObjectProxy)
                    object.remote_interface = @interface
                    object
                else
                    super
                end
            end
        end

	def method_missing(m, *args) # :nodoc:
            if interfaces.has_key?(m)
                return interfaces[m]
            end
	    call_interface(m, *args)

	rescue Exception => e
	    raise e, e.message, e.backtrace
	end

        def call_interface(m, *args)
            args = args.droby_dump(nil)
            result = @interface.send(m, *args)

            if result.kind_of?(ShellInterface)
                interfaces[m] = RemoteShellInterface.new(result)
            elsif result.kind_of?(RemoteObjectProxy)
                result.remote_interface = @interface
                result
            elsif result.respond_to?(:proxy)
                DRobyManager.local_object(result)
            else result
	    end
        end
    end

    # Base class for synchronously calling methods on a running Roby plan
    class ShellInterface
        include DRbUndumped

        # The engine this shell acts on
        attr_reader :engine

        # The plan this shell acts on
        def plan
            @engine.plan
        end
        
        def initialize(engine)
            @engine = engine
        end

        # Synchronously call +m+ on +object+ with the given arguments. This,
        # along with the implementation of RemoteInterface#method_missing,
        # ensures that no interactive operations are performed outside the
        # control thread.
	def call(object, m, *args)
	    engine.execute do
                if object.kind_of?(Roby::Task) && m.to_s =~ /!$/
                    event_name = $`
                    # Check if the called event is terminal. If it is the case,
                    # discard the task before calling it, and make sure the user
                    # will get a message
                    #
                    if object.event(event_name).terminal?
                        plan.unmark_mission(object)
                        object.on(:stop) { |ev| pending_messages << [:info, "task #{ev.task} stopped by user request"] }
                    else
                        object.on(event_name) { |ev| pending_messages << [:info, "done emitting #{ev.generator}"] }
                    end
                end

		object.send(m, *args)
	    end
	end
    end

    # RemoteInterface objects are used as local representation of remote
    # interface objects.  They offer a seamless interface to a remotely running
    # Roby controller.
    class RemoteInterface < RemoteShellInterface
        # Create a RemoteInterface object for the remote object represented by
        # +interface+, where +interface+ is a DRbObject for a remote Interface
        # object.
	def initialize(interface)
	    super(interface)
            reconnect
        end

        def reconnect
            # Verify that passing objects around works fine
            obj = @interface.connection_test_object
            @interface.connection_test(obj)

            # Check which plugins should be loaded (if any). Note that not being
            # able to load a plugin is only a warning in this context, as the
            # shell can work anyway (but possibly in a degraded mode)
            @interface.loaded_plugins.each do |plugin|
                begin
                    Roby.app.using(plugin)
                rescue ArgumentError
                    Robot.warn "the remote controller is using the '#{plugin}' Roby plugin, but it does not seem to be available on this machine. The shell functionality might be degraded by that"
                end
            end

            Roby.app.call_plugins(:setup, Roby.app)

            remote_models = @interface.models
            remote_models.each do |klass|
                klass = klass.proxy(nil)

                ## The empty? test is a workaround. See ticket#113
                if klass.respond_to?(:remote_name) && klass.remote_name && klass.remote_name =~ /^[A-Z][\w:]+/
                    # This is a local proxy for a remote model. Add it in our
                    # namespace as well.
                    path  = klass.remote_name.split '::'
                    klass_name = path.pop
                    mod = Object
                    while !path.empty?
                        name = path.shift
                        mod = mod.define_or_reuse(name) { Module.new }
                    end
                    mod.define_or_reuse(klass_name, klass)
                    new_model(klass.remote_name, klass)
                end
            end
            nil
        end

        # Hook called when a new remote model gets imported locally (for use in
        # the shell)
        def new_model(model_name, model)
            super if defined? super
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

        # Returns the available actions of this Planner class
        # and allows access to the actions' signature 
        def actions_with_signature(with_advanced = false)
            methods = @interface.actions
            if !with_advanced
                methods = methods.find_all {|m| !m.advanced? }            
            end
            methods
        end

        # Displays a summary of the available actions
        #
        # See #actions for details
        def actions_summary(with_advanced = false)
            methods = self.actions
            if !with_advanced
                methods = methods.delete_if do |m|
                    m.advanced?
                end
            end

            if !methods.empty?
                puts
                desc = methods.map do |p|
                    doc = p.doc || ["(no description set)"]
                    Hash['Name' => "#{p.name}!", 'Description' => Array(doc).join("\n")]
                end

                ColumnFormatter.from_hashes(desc, STDOUT,
                                            :header_delimiter => true, 
                                            :column_delimiter => "|",
                                            :order => %w{Name Description})
                puts
            end

            nil
        end

        # A class that (in a very limited way) makes a pretty print object "look
        # like" an IO object
        class PPIOAdaptor
            def print(text)
                first = true
                text.split("\n").each do |text|
                    pp.breakable if !first
                    pp.text text
                    first = false
                end
            end
            def puts(text)
                print text
                pp.breakable
            end
        end

        # Value returned by #actions to allow for enumerating actions and
        # redefine #pretty_print to display the action information
        class ActionList
            attr_reader :actions
            def initialize(actions)
                @actions = actions
            end

            def pretty_print(pp)
                if actions.empty?
                    pp.text "No actions defined"
                    return
                end

                puts
                desc = actions.map do |p|
                    doc = p.doc || ["(no description set)"]
                    Hash['Name' => "#{p.name}!(#{p.arguments.map(&:name).sort.join(", ")})", 'Description' => doc.join("\n")]
                end

                ColumnFormatter.from_hashes(desc, PPIOAdaptor.new(pp),
                                            :header_delimiter => true, 
                                            :column_delimiter => "|",
                                            :order => %w{Name Description})
            end

            def each(&block)
                actions.each(&block)
            end
            include Enumerable

            def pretty_print(pp)
                display_action_description(m)
                puts
            end
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
                    'Lifetime' => (Roby.format_time(Time.at(lifetime)) if lifetime)
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

        def describe(action)
            pp action
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
help                              | this help message                                       |
describe(action)                  | displays details about the given action                 |
missions                          | displays the set of running missions with their status  |
running_tasks                     | displays the set of running tasks with their status     |
unmark(task)                      | remove permanent or mission mark on +task+              |
jobs                              | the list of actions started with the associated job ID  |
job ID                            | returns the task object for job ID                      |
kill_job ID                       | stop job with the given ID                              |
reload_models                     | reload all models                                       |
reload_actions                    | reload action definitions (faster than reload_models)   |

            EOHELP
        end

        # Removes any permanent/mission mark on +task+, making it eligible for
        # GC
        def unmark(task)
            @interface.unmark(task)
            nil
        end

        # Displays the set of running jobs
        def jobs
            call_interface(:jobs).each do |srv|
                puts "#{srv.id} #{srv.name}! #{srv.task.method_missing(:to_s)}"
            end
            nil
        end

        def job(id)
            call_interface(:job, id)
        end
    end

    # This class is used to interface with the Roby event loop and plan. It is the
    # main front object when accessing a Roby core remotely
    class Interface < ShellInterface
        include Robot

        # This module defines the hooks needed to plug Interface objects onto
        # ExecutionEngine
	module GatherExceptions
            # Each error gets its own ID so that it can be separated from the
            # other, and matched between different shells
            attribute(:current_exception_id) { 0 }

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
                    msg = []
                    exception = Roby.format_exception(error.exception)
                    exception[0] = "#{name} #{self.current_exception_id += 1}: #{exception[0]}"
                    msg.concat(exception)
		    msg << "The following tasks have been killed:"

		    tasks.each do |t|
                        task_string = ""
                        if error.exception.involved_plan_object?(t)
                            task_string = "#{t.class}:0x#{t.address.to_s(16)}"
                        else
                            PP.pp(t, task_string)
                        end
                        msg.concat(task_string.split("\n"))
                    end

		    interfaces.each do |iface|
			iface.pending_messages << [:error, msg]
		    end
		end
	    end

            # Pushes information about a nonhandled, non-fatal exception on all
            # remote interfaces connected to us
            def nonfatal_exception(error, task)
		super if defined? super
		push_exception_message("non-fatal exception", error, [task])
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

        # The set of pending messages that are to be displayed on the remote interface
	attr_reader :pending_messages
        # Creates a local server for a remote interface, acting on +control+
	def initialize(engine)
            super(engine)
	    @pending_messages = Queue.new
            @jobs = Array.new

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
	    plan.query_roots(result_set, m_relation.proxy(Distributed::DumbManager)).
		map { |t| RemoteObjectProxy.new(t) }
	end

        # Returns a DRbObject on the given named constant. Use this to get a
        # remote interface to a given object, not taking into account its
        # 'marshallability'
	def remote_constant(name)
	    DRbObject.new(name.to_s.camelcase(true))
	end

        # Reload all models from this Roby application
        #
        # Do NOT do this while the robot does critical things
        def reload_models
            Roby.execute do
                Roby.app.reload_models
            end
            nil
        end

	# @deprecated use {#reload_actions} instead
	def reload_planners
	    reload_actions
	end

	# Reload the Roby framework code
	def reload_actions
            Roby.execute do
                Roby.app.reload_actions
            end
	    nil
	end

        # Returns the set of task models as DRobyTaskModel objects. The standard
        # Roby task models are excluded.
	def models
	    models = []
	    engine.execute do
                [Actions::Interface, Task].each do |root_model|
                    root_model.each_submodel do |m|
                        if !m.private_model? && m.name !~ /^Roby::/
                            models << m
                        end
                    end
                end
	    end
            models.map { |t| t.droby_dump(nil) }
	end

        def droby_call(m, *args)
            send(m, *args).droby_dump(nil)
        end

        # Returns the set of action description objects that describe the methods
        # exported in the application's planners.
	def actions
	    Roby.app.planners.
		inject([]) do |list, p|
                    list.concat(p.each_action.to_a)
                end.sort_by(&:name).droby_dump(nil)
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
                shell.pending_messages << [:info, "[#{id}] #{name}!: #{self.task} has been replaced by #{new_task}"]
                super
            end
        end

        def verify_no_drbobject(object)
            if object.kind_of?(DRbObject)
                raise ArgumentError, "found a DRbObject"
            elsif object.respond_to?(:to_str) # on ruby 1.8, strings respond to #each ...
                return
            elsif object.respond_to?(:each)
                object.each do |*values|
                    values.each do |v|
                        verify_no_drbobject(v)
                    end
                end
            end
        end


	# Tries to find a planner method which matches +name+ with +args+. If it finds
	# one, creates a task planned by a planning task and yields both
	def method_missing(name, *args)
            args = args.proxy(Distributed::DumbManager)

	    if name.to_s =~ /!$/
		name = $`.to_sym
            elsif Robot.respond_to?(name)
                return Robot.send(name, *args)
            elsif action = Robot.find_action_from_name(name.to_s)
                return action.last.droby_dump(nil)
            else
		super
	    end

	    if args.size > 1
		raise ArgumentError, "wrong number of arguments (#{args.size} for 1) in #{name}!"
	    end

	    options = (args.first || {})
            # Verify that all options are properly resolved (i.e. no DrbObject
            # are lying around)
            verify_no_drbobject(options)

            shell = self
            engine.execute do
                # Call #jobs to delete finished jobs
                self.jobs

                task, planner = Robot.prepare_action(plan, name, options)

                service = PlanService.new(task)
                service.extend PlanServiceUI
                service.shell = shell
                service.id    = PlanServiceUI.allocate_id
                service.name  = name
                service.when_finalized  { shell.pending_messages << [:info, "[#{service.id}] #{name}!: task #{service.task} has been removed"] }
                service.on(:start)   { |ev| shell.pending_messages << [:info, "[#{service.id}] #{name}!: task #{ev.task} started"] }
                service.on(:failed)  { |ev| shell.pending_messages << [:info, "[#{service.id}] #{name}!: task #{ev.task} failed"] }
                service.on(:success) { |ev| shell.pending_messages << [:info, "[#{service.id}] #{name}!: task #{ev.task} finished successfully"] }

                planner.on(:failed) do |ev|
                    exception = ev.context.first
                    msg = ["planning #{name} failed with"]
                    Roby.format_exception(exception).each do |line|
                        msg << line
                    end
                    shell.pending_messages << [:error, msg]
                end

                shell.pending_messages << [:info, "[#{service.id}] #{name}! started to plan"]

                plan.add_mission(task)
                @jobs << service
                RemoteService.new(service)
            end
	end

        def jobs
            engine.execute do
                @jobs.delete_if { |j| !j.task.plan }
                @jobs.delete_if { |j| j.finished? }
                @jobs.dup.map { |t| RemoteService.new(t) }
            end
        end

        def job(id)
            engine.execute do
                if t = @jobs.find { |j| j.id == id }
                    RemoteService.new(t)
                end
            end
        end

        def kill_job(id)
            engine.execute do
                if j = job(id)
                    if j.running?
                        j.stop!
                    else
                        plan.unmark_mission(j)
                    end
                end
                nil
            end
        end

        def connection_test_object
            @test_object = Object.new
            DRbObject.new(@test_object)
        end
        def connection_test(obj)
            if obj.kind_of?(DRbObject)
                raise "cannot pass remote objects in connection (#{obj.__drburi} != #{DRb.current_server.uri})"
            end
            @test_object = nil
        end

        # Returns the set of Roby plugins currently loaded in the application
        def loaded_plugins
            Roby.app.plugins.map(&:first)
        end
    end
end

