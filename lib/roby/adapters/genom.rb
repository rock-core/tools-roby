require 'roby'
require 'roby/control'
require 'roby/relations/executed_by'
require 'forwardable'

module Roby::Genom
end

require 'genom/module'
require 'genom/environment'

module Roby::Genom
    include Genom

    @genom_rb = ::Genom
    class << self
	extend Forwardable
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

    class RequestTimeout < Roby::TaskModelViolation
    end

    class StartFailed < Roby::TaskModelViolation
    end

    # Base class for the task models defined for Genom modules requests
    #
    # See Roby::Genom::GenomModule
    class RequestTask < Roby::Task
	include RobyMapping

	class << self
	    attr_reader :timeout
	end

	# The genom activity if the task is running, or nil
	attr_reader :activity
	# The abort activity if we are currently aborting, or nil
	attr_reader :abort_activity

	# Creates a new Task object to map a Genom request
	# +arguments+ is an array holding the request arguments. TypeError
	# is raised if their type does not match the request type, and
	# ArgumentError is raised if the argument count is wrong
	def initialize(arguments, genom_request)
	    super(arguments)

	    # Check that +arguments+ are valid for genom_request
	    genom_request.filter_input(genom_arguments)
	    @request    = genom_request

	    on(:stop) { @abort_activity = @activity = nil }
	end

	def genom_arguments
	    if arguments.has_key?(:request_options)
		arguments[:request_options]
	    else
		arguments
	    end
	end

	# Starts the request
	def start(context = nil)
	    args = genom_arguments
	    if Hash === args
		@activity = @request.call(args)
	    else
		@activity = @request.call(*args)
	    end
	    Roby::Genom.running << self
	end
	event :start
	
	# The request has been interrupted
	def interrupted(context)
	    @abort_activity = activity.abort
	end
	event :interrupted
	on :interrupted => :failed

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
		def to_s
		    "[#{request.arguments.inspect}] #{__to_s__}"
		end
	    end
	    

	    if !running?
		event(:start).emit_failed(StartFailed, e)
	    else
		emit :failed, e
	    end
	end

	def self.needs(request)
	    unless Class === request
		request = roby_module.const_get(request)
	    end

	    precondition(:start, "#{name} needs #{request} to have been executed at least once") do |context|
		Roby::Task.each_task(request) { |rq| break(true) if rq.success? }
		false
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
	gen_mod     = rb_mod.genom_module
	klassname   = rq_name.camelize
	method_name = gen_mod.request_info[rq_name].method_name

	Roby.debug { "Defining task model #{klassname} for request #{rq_name}" }
	define_task(rb_mod, klassname) do
	    Class.new(RequestTask) do
		singleton_class.class_eval do
		    define_method(:roby_module)	    { rb_mod }
		    define_method(:request_name)    { rq_name }
		end

		class_attribute :request => gen_mod.request_info[method_name]

		def initialize(arguments = {}) # :nodoc:
		    arguments = Roby::Genom.arguments_genom_to_roby(arguments)

		    super(arguments, self.class.request)
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

	    # Never garbage-collect runner tasks
	    Roby::Control.instance.plan.insert(self)
	    @output_io = roby_module.output_io

	    # Make sure there is a init() method defined in the Roby module if there is one in the
	    # Genom module
	    if !roby_module.respond_to?(:init) && genom_module.respond_to?(:init)
		init_request = genom_module.request_info.find { |_, rq| rq.init? }.last.name

		raise ArgumentError, "the Genom module '#{genom_module.name}' defines the init request #{init_request}. You must define a singleton 'init' method in '#{roby_module.name}' which initializes the module"
	    end
	end

	# Start the module
	#
	# If the module has an init request, the ::init module method is started and :ready is emitted
	# when if finishes successfully (see RunnerTask). Otherwise, :ready is emitted immediately otherwise
	def start(context)
	    mod = ::Genom::Runner.environment.start_module(genom_module.name, output_io)
	    mod.wait_running
	    emit(:start, context)

	    init = if roby_module.respond_to?(:init)
		       roby_module.init
		   end

	    # Redefine GenomModule#dead! so that :failed gets
	    # emitted when the module process is killed
	    unless genom_module.respond_to?(:__roby__dead!)
		genom_module.singleton_class.class_eval do
		    attr_accessor :roby_runner_task
		    alias :__roby__dead! :dead!
		    def dead!
			__roby__dead!
			@roby_runner_task.emit(:failed, "process died") if Roby::EventGenerator.propagate?
		    end
		end
	    end
	    genom_module.roby_runner_task = self

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
	# Event emitted when the module is running
	event :start

	# Event emitted when the module has been initialized
	event :ready

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

	# Get the poster_info object for +name+
	def poster(name)
	    genom_module.poster(name)
	end

	# Builds a Task object based on a control task object, where
	# * the start event starts the control task start event
	# * the start event is emitted when the control task finishes successfully
	# * the stop event has no effect whatsoever
	def control_to_exec(name, *args)
	    control = send(name, *args)
	    klass = Class.new(Roby::Task) do
		@name = "#{name.to_s.gsub('!', '')}Control"
		def self.name; @name end
		def start(context)
		    event(:start).emit_on control.event(:success)
		    control.start!(context)
		end
		event :start

		event :stop, :command => true

		executed_by control.class.execution_agent
	    end

	    klass.new
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
	attribute(:uses) { Array.new }
	# If +name+ is a used module
	def uses?(name); uses.include?(name.to_s) end

	# Load the following modules and autorequire extension
	# found in +autoload_path+. Updates the +uses+ attribute
	def using(*modules)
	    modules.each do |modname| 
		modname = modname.to_s
		
		::Roby::Genom::GenomModule(modname, :output => output_io) 
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
	    
	    uses |= modules.map { |name| name.to_s }
	end
    end
    Roby::State.genom = GenomState.new
end

