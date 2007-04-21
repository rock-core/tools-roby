require 'roby'
require 'forwardable'

module Genom; end
module Roby::Genom; end
require 'genom'
require 'genom/module'
require 'genom/environment'

module Roby::Genom
    def self.component_name; 'genom' end

    @genom_rb = ::Genom
    if @genom_rb == Roby::Genom
	raise "you must not load Genom.rb by yourself"
    end

    class << self
	extend Forwardable
	attr_reader :genom_rb
	def_delegators(:@genom_rb, :connect)
	def_delegators(:@genom_rb, :disconnect)
    end

    extend Logger::Hierarchy
    extend Logger::Forward
    
    module RobyMapping
	def roby_module;  self.class.roby_module end
	def genom_module; self.class.roby_module.genom_module end
	def config;	  self.class.config end

	module ClassExtension
	    def config;		roby_module.config end
	    def genom_module;	roby_module.genom_module end
	end
    end

    @running = Array.new
    class << self
	# The list of running Genom tasks
	attr_reader :running
    end

    # Register the event processing in Roby event loop
    Roby::Control.event_processing << lambda do 
	Roby::Genom.running.each { |task| task.poll } 
    end

    # Raised when a request failed because of Pocolibs's timeout.
    # The 'task' attribute is the target request.
    class RequestTimeout < Roby::TaskModelViolation; end

    # Base class for the task models defined for Genom modules requests
    #
    # See Roby::Genom::GenomModule
    class RequestTask < Roby::Task
	include RobyMapping

	class << self
	    attr_reader :timeout
	end

	argument :request_name

	# The genom activity if the task is running, or nil
	attr_reader :activity
	# The abort activity if we are currently aborting, or nil
	attr_reader :abort_activity

	# The request object itself
	attr_reader :request
	attr_reader :request_name

	# Creates a new Task object to map a Genom request
	# +arguments+ is an array holding the request arguments. TypeError
	# is raised if their type does not match the request type, and
	# ArgumentError is raised if the argument count is wrong
	def initialize(arguments)
	    @request_name = arguments[:request_name]
	    super(arguments)
	end

	def genom_arguments
	    genom_args = if arguments.has_key?(:request_options)
			     arguments[:request_options].dup
			 else arguments.dup
			 end
	    genom_args.delete(:request_name)
	    genom_args
	end

	# Starts the request
	def start(context = nil)
	    args = genom_arguments
	    if Hash === args
		@activity = request.call(args)
	    else
		@activity = request.call(*args)
	    end
	    start_polling
	end
	event :start
	
	# The request has been interrupted
	def interrupted(context)
	    @abort_activity = activity.abort
	end
	event :interrupted
	forward :interrupted => :failed

	# Stops the request. It emits :interrupted
	def stop(context)
	    interrupted!(context)
	end
	event :stop
	on(:stop) { |event| Roby::Genom.running.delete(event.task) }

	# Poll on the status of the activity
	def poll
	    # Check abort status. This can raise ReplyTimeout, which is
	    # the only event we are interested in
	    abort_activity.try_wait if abort_activity

	    activity.try_wait # update status
	    if !running? && activity.reached?(:intermediate)
		emit :start
	    end

	    if activity.reached?(:final)
		emit :success, activity.output
	    end

	rescue ::Genom::ReplyTimeout => e # timeout waiting for reply
	    if abort_activity
		event(:stop).emit_failed(RequestTimeout.new(self), e.message)
	    else
		stop_polling
		event(:start).emit_failed(RequestTimeout.new(self), "timeout waiting for intermediate reply: #{e.message}")
	    end

	rescue ::Genom::ActivityInterrupt # interrupted
	    emit :start, nil if !running?
	    emit :interrupted 

	rescue ::Genom::GenomError => e # the request failed
	    this = self
	    e.singleton_class.class_eval do
		define_method(:request) { this }
		alias :__to_s__ :to_s
		def to_s; "[#{request.arguments}] #{__to_s__}" end
	    end
	    

	    emit :start, nil if !running?
	    emit :failed, e
	end
	def start_polling; Roby::Genom.running << self end
	def stop_polling; Roby::Genom.running.delete(self) end

	def self.needs(request)
	    unless Class === request
		request = roby_module.const_get(request)
	    end

	    precondition(:start, "#{name} needs #{request} to have been executed at least once") do |generator, context|
		generator.plan.enum_for(:each_task).any? do |task|
		    request === task && request.success?
		end
	    end
	end
    end

    # Builds and registers a task class as a subclass of the module.
    # Additionally, it defines a task_name!(*args) singleton method
    # to build a task instance more easily
    def self.define_task(mod, name, &block) # :nodoc:
	klass = mod.define_under(name, &block)
	method_name = name.underscore
	mod.singleton_class.send(:define_method, method_name + '!') { |*args| klass.new(args) }
    end

    def self.arguments_genom_to_roby(arguments)
	case arguments
	when Array then Hash[:request_options, arguments]
	when Hash then arguments
	else raise TypeError, "unexpected #{arguments}"
	end
    end

    # Define a Task model for the given request
    # The new model is a subclass of Roby::Genom::Request
    def self.define_request(rb_mod, rq_name) # :nodoc:
	gen_mod = rb_mod.genom_module
	rq_info = gen_mod.request_info[rq_name]
	klassname   = rq_name.camelize
	if rq_info.control?
	    klassname << "Control"
	end
	method_name = rq_info.method_name

	Roby.debug { "Defining task model #{klassname} for request #{rq_name}" }
	define_task(rb_mod, klassname) do
	    Class.new(RequestTask) do
		singleton_class.class_eval do
		    define_method(:roby_module)	   { rb_mod }
		    define_method(:request_name)   { rq_name }
		end

		def initialize(arguments = {}) # :nodoc:
		    arguments = Roby::Genom.arguments_genom_to_roby(arguments)
		    arguments[:request_name] = self.class.request_name
		    super(arguments)

		    @request = genom_module.request_info[request_name]
		    request.filter_input(genom_arguments)

		    on(:stop) { @abort_activity = @activity = nil }
		end
		
		# requests need the module process
		executed_by roby_module.const_get(:Runner)
	    end
	end
    end

    # Runner tasks represent the module process. The :start event is emitted when the process
    # is started and can receive a request, :ready when the init request ran successfully and
    # :failed when the process has quit. :failed is controlable, and sends the abort request.
    #
    # == Module initialization
    # If the Roby-defined module defines an +init+ module method, this method should
    # return an event object which is then forwarded to the :ready event. Alternatively, 
    # it can return a task object in which case
    #   * the Runner task will be a parent of this task
    #   * :ready is emitted when task.event(:success) is
    #
    # For instance, for a Pom module
    #
    # module Roby::Genom::Pom
    #   def self.init
    #	# call the init request
    #	# and return an EventGenerator object or a Task object
    #	# (in which case, task.event(:success) is considered)
    #   end
    # end
    #
    # If the module has an init request, then this +init+ module method is mandatory and
    # should run genom's init request.
    #
    # See Roby::Genom::GenomModule
    class RunnerTask < Roby::Task
	include RobyMapping

	# A redirection for the Genom module output. See Genom::GenomModule.new documentation
	# for the allowed values
	#
	# It is initialized by the value of the :output argument given to GenomModule
	#
	# Note that changing it after the :start event is emitted has no effect
	attr_accessor :output_io

	def initialize(arguments = {})
	    arguments = Roby::Genom.arguments_genom_to_roby(arguments)
	    super(arguments)

	    if self.class.respond_to?(:roby_module)
		@output_io = roby_module.output_io

		# Make sure there is a init() method defined in the Roby module if there is one in the
		# Genom module
		if !roby_module.respond_to?(:init) && genom_module.respond_to?(:init)
		    init_request = genom_module.request_info.find { |_, rq| rq.init? }.last.name

		    raise ArgumentError, "the Genom module '#{genom_module.name}' defines the init request #{init_request}. You must define a singleton 'init' method in '#{roby_module.name}' which initializes the module"
		end
	    end
	end

	def plan=(new_plan)
	    return if plan == new_plan
	    super
	    plan.permanent(self) if plan
	end

	# Start the module
	#
	# If the module has an init request, the ::init module method is started and :ready is emitted
	# when if finishes successfully (see RunnerTask). Otherwise, :ready is emitted immediately otherwise
	def start(context)
	    ::Genom::Runner.environment.start_module(genom_module.name, output_io)
	    poll_running
	    Roby::Control.event_processing << method(:poll_running)
	end
	# Event emitted when the module is running
	event :start

	def poll_running
	    if genom_module.wait_running(true)
		Roby::Control.event_processing.delete(method(:poll_running))
		emit :start, nil
	    end

	rescue RuntimeError => e
	    event(:start).emit_failed e.message
	end

	def ready(context)
	    # Redefine GenomModule#dead! so that :failed gets
	    # emitted when the module process is killed
	    unless genom_module.respond_to?(:__roby__dead!)
		genom_module.singleton_class.class_eval do
		    attr_accessor :roby_runner_task
		    alias :__roby__dead! :dead!
		    def dead!
			__roby__dead!

			task = self.roby_runner_task
			Roby::Control.once do
			    # we sometime get the event more than once ...
			    if !task.finished?
				task.emit(:failed, "process died")
			    end
			end
		    end
		end
	    end
	    genom_module.roby_runner_task = self
	    roby_module.config.stable!(true)

	    # Get the init request if it is needed
	    init = if roby_module.respond_to?(:init)
		       roby_module.init
		   end

	    # If there is an init task, wait for it. Otherwise,
	    # send the event 
	    if !init
		emit :ready
	    else
		if init.respond_to? :to_task
		    init = init.to_task
		    realized_by init
		    init.start!
		    init = init.event(:success)
		end
		event(:ready).emit_on init
	    end
	end
	# Event emitted when the module has been initialized
	event :ready
	on :start => :ready

	# Stops the module
	def failed(context)
	    ::Genom::Runner.environment.stop_module(genom_module.name)
	    # :failed will be emitted by the dead! handler
	end

	# Emitted when the module process terminated
	event :failed, :terminal => true

	def stop(context); failed!(context) end
	event :stop
    end

    Poster = ::Genom::Poster

    # Base functionalities for Genom modules. It extends
    # the modules defined by GenomModule()
    module ModuleBase
	# The Genom.rb's GenomModule object
	attr_reader :genom_module
	# The module name
       	attr_reader :name
	# See RunnerTask#output_io
	attr_reader :output_io

	# Needed by executed_by
	def new_task; runner!(nil) end

	# The configuration structure got from the State object
	def config
	    State.genom.send(genom_module.name)
	end

	# True if we are running in simulation
	def simulation?
	    defined?(::Genom::Runner::Simulation) && ::Genom::Runner::Simulation === ::Genom::Runner.environment
	end

	# Get the poster_info object for +name+
	def poster(name)
	    genom_module.poster(name)
	end

	# Converts a control request 'name' into a task model for which
	# * the start event starts the control task start event
	# * the start event is emitted when the control task finishes successfully
	# * the task is interruptible and the failed event command is the 
	#   block given (if any)
	#
	# Returns the new model
	def control_to_exec(name, &failed_command)
	    name = name.to_s
	    control_model = const_get("#{name}Control")

	    Roby::Genom.define_task(self, name) do
		Class.new(Roby::Task) do
		    @control_model = control_model
		    class << self
			attr_reader :control_model
		    end

		    attr_reader :control
		    def initialize(args)
			@control = self.class.control_model.new(args)
			super(control.arguments)
			realized_by control
		    end

		    event :start do |context|
			event(:start).realize_with(control)
			control.start!(context)
		    end

		    if failed_command
			event(:failed, :terminal => true, &failed_command)
		    else
			event(:failed, :terminal => true, :command => true)
		    end
		    interruptible

		    executed_by control_model.execution_agent
		end
	    end
	end
    end
    
    # Loads a new Genom module and defines the task models for it
    #
    # For a +foo+ genom module, GenomModule('foo') defines the following:
    # * a Roby::Genom::Foo namespace
    # * a Roby::Genom::Foo::Runner task which represents the module process itself (subclass of Roby::Genom::RunnerTask)
    # * a Roby::Genom::Foo::MyRequest for each request in foo (subclass of Roby::Genom::RequestTask)
    #
    # Moreover, it defines a #genom_module attribute in the Foo namespace, which is Genom.rb's 
    # GenomModule object, and a #request_name method which returns
    # RequestName.new
    #
    # See the documentation of ModuleBase, which defines the common methods and
    # attributes for each generated module.
    #
    # == Options
    # This method takes the same arguments as Genom.rb's GenomModule.new method. Note however that neither the 
    # :constant, nor the :start options can be set when mapping Genom modules into Roby
    # It adds the +output+ option, which gives an IO object to which the module 
    # output should be redirected.
    #
    #
    def self.GenomModule(name, options = Hash.new)
	# Handle options
	if options[:constant] || options[:start]
	    raise ArgumentError, "neither the :constant nor the :start options can be set when running in Roby"
	end
	output_io = options.delete(:output) # only to be used by the Runner task
	options = { :auto_attributes => true, :lazy_poster_init => true, :constant => false }.merge(options)

	# Get the genom module
	gen_mod = Genom::GenomModule.new(name, options)

	# Check for the presence of a module with the same name
	modname = gen_mod.name.camelize
	rb_mod = Roby::Genom.define_under(modname) { Module.new }
	if !rb_mod.is_a?(Module)
	    raise "module #{modname} already defined, but it is not a Ruby module: #{rb_mod}"
	elsif rb_mod.respond_to?(:genom_module)
	    if rb_mod.genom_module == gen_mod
		return rb_mod
	    else
		raise "module #{modname} already defined, but it does not seem to be associated to #{name}"
	    end
	end

	Roby.debug { "Defining #{modname} for genom module #{name}" }

	# Define the base services for the module
	rb_mod.class_eval do
	    @genom_module = gen_mod
	    @name = "Roby::Genom::#{modname}"
	    @output_io = output_io
	    extend ModuleBase
	end

	# Define the runner task
	define_task(rb_mod, 'Runner') do
	    Class.new(RunnerTask) do
		singleton_class.class_eval do
		    define_method(:roby_module) { rb_mod }
		    define_method(:name) { "#{rb_mod.name}::Runner" }
		end

		on(:stop) { genom_module.disconnect if genom_module.connected? }
	    end
	end

	gen_mod.request_info.each do |req_name, req_def|
	    define_request(rb_mod, req_name) if req_name == req_def.name
	end

	return rb_mod
    end

    class GenomState < Roby::StateSpace
	# Each time a module +name+ is loaded by #using, 
	# we check for "#{name}.rb" in each path
	# in +autoload_path+ and require it if it exists
	attribute(:autoload_path) { Array.new }

	attr_accessor :output_io

	# The list of the module names that have been loaded by #using
	attribute(:used_modules) { Hash.new }
	# If +name+ is a used module
	def uses?(modname); used_modules.any? { |n, _| n == modname.to_s } end

	attribute(:ignored_modules) { Array.new }
	def ignores?(name); ignored_modules.include?(name.to_s) end

	# Ignore configuration for the given modules. For instance, in
	#
	#   State::Genom do |g|
	#	g.ignoring :pom
	#	g.pom do |p|
	#	    p.some_configuration = true
	#	end
	#   end
	#
	# The block given to g#pom is never called
	def ignoring(*modules)
	    modules.map do |n|
		n = n.to_s
		if uses?(n)
		    raise ArgumentError, "#{n} is both used and ignored", caller(3)
		end
		return if ignores?(n)
	       	ignored_modules << n
	    end
	end

	# Redefine method_missing to disable module-specific configuration
	# when the module is not in use
        def method_missing(name, *args, &update) # :nodoc:
	    return if ignored_modules.include?(name.to_s) && update
	    super
	end

	# Load the following modules and autorequire extension
	# found in +autoload_path+. Updates the +used_modules+ attribute
	def using(*modules)
	    modules.each do |modname| 
		modname = modname.to_s
		next if uses?(modname) # already loaded
		if ignores?(modname)
		    raise ArgumentError, "#{modname} is both used and ignored", caller(3)
		end
		genmod = used_modules[modname] = Roby::Genom::GenomModule(modname, :output => output_io)

		# Import the module into global namespace directly
		Object.const_set(genmod.name.gsub(/^Roby::Genom::/, ''), genmod)
		
		self.autoload_path.each do |path|
		    extfile = File.join(path, modname)
		    begin
			if require extfile
			    Genom.debug "loaded #{extfile}"
			end
		    rescue LoadError => e
			raise if e.backtrace.find { |level| level =~ /#{Regexp.quote(extfile)}/ }
		    end
		end
	    end
	end
    end
    Roby::State.genom = GenomState.new
end

