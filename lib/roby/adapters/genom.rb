require 'roby'
require 'roby/event_loop'
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
    Roby.event_processing << lambda do 
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
	# Arguments for the request itself
	attr_reader :arguments

	# Creates a new Task object to map a Genom request
	# +arguments+ is an array holding the request arguments. TypeError
	# is raised if their type does not match the request type, and
	# ArgumentError is raised if the argument count is wrong
	def initialize(arguments, genom_request)
	    # Check that +arguments+ are valid for genom_request
	    genom_request.filter_input(*arguments)

	    @arguments  = arguments
	    @request    = genom_request
	    super()

	    on(:stop) { @abort_activity = @activity = nil }
	end

	def start(context = nil)
	    @activity = @request.call(*arguments)
	    Roby::Genom.running << self
	end
	event :start
	
	def interrupted(context)
	    @abort_activity = activity.abort
	end
	event :interrupted
	on :interrupted => :failed

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
		event(:start).emit_failed(RequestTimeout.new(self), e.message)
	    end

	rescue ::Genom::ActivityInterrupt # interrupted
	    emit :start, nil if !running?
	    emit :interrupted 

	rescue ::Genom::GenomError => e # the request failed
	    if !running?
		event(:start).emit_failed(StartFailed, e.to_s)
	    else
		emit :failed, e.message
	    end
	end
    end

    # Builds and registers a task class as a subclass of the module.
    # Additionally, it defines a task_name!(*args) singleton method
    # to build a task instance more easily
    def self.define_task(mod, name, &block)
	klass = mod.define_under(name, &block)
	method_name = name.underscore
	mod.singleton_class.send(:define_method, method_name + '!') { |*args| klass.new(*args) }
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

		def initialize(*arguments)
		    super(arguments, self.class.request)
		end
		def self.name
		    "#{roby_module.name}::#{request_name}"
		end

		executed_by roby_module.const_get(:Runner)
	    end
	end
    end

    # Base functionalities for Runner tasks
    #
    # See Roby::Genom::GenomModule
    class RunnerTask < Roby::Task
	include RobyMapping

	singleton_class.class_eval do
	    define_method(:name) { "#{roby_module.name}::Runner" }
	end

	def initialize
	    # Make sure there is a init() method defined in the Roby module if there is one in the
	    # Genom module
	    if !roby_module.respond_to?(:init) && genom_module.respond_to?(:init)
		init_request = genom_module.request_info.find { |_, rq| rq.init? }.last.name

		raise ArgumentError, "the Genom module '#{genom_module.name}' defines the init request #{init_request}. You must define a singleton 'init' method in '#{roby_module.name}' which initializes the module"
	    end
	    super
	end

	def start(context)
	    mod = ::Genom::Runner.environment.start_modules(genom_module.name).first
	    mod.wait_running
	    emit :start

	    init = if roby_module.respond_to?(:init)
		       roby_module.init
		   end

	    if !init
		emit :ready
	    elsif init.respond_to? :to_task
		init = init.to_task
		realized_by init
		init.start!
		init = init.event(:success)
	    end

	    if init
		event(:ready).emit_on init
	    end
	end
	event :start
	event :ready

	def failed(context)
	    ::Genom::Runner.environment.stop_modules genom_module.name
	    emit :failed, context
	end
	event :failed, :terminal => true

	def stop(context)
	    failed!(context)
	end
	event :stop
    end

    # Base functionalities for Genom modules. It extends
    # the modules defined by GenomModule()
    module ModuleBase
	attr_reader :genom_module, :name
	def new_task; Runner.new end

	def config
	    State.genom.send(genom_module.name)
	end

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
    # GenomModule('foo') defines the following:
    # * a Roby::Genom::Foo namespace
    # * a Roby::Genom::Foo::Runner task which deals with running the module itself
    # * a Roby::Genom::Foo::<RequestName> for each request in foo
    #
    # Moreover, it defines a #module attribute in the Foo namespace, which is the 
    # ::Genom::GenomModule object, and a #request_name method which returns
    # RequestName.new
    #
    # The main module defines the singleton method new_task so that a module
    # can be used in ExecutedBy relationships
    # 
    # If options is given, it is forwarded to GenomModule.new. Note that the :constant option
    # cannot be set when mapping Genom modules into Roby
    # 
    def self.GenomModule(name, options = Hash.new)
	# Get the genom module
	if options[:constant]
	    raise ArgumentError, "the :constant option cannot be set when running in Roby"
	elsif options[:start]
	    raise ArgumentError, "the :start option cannot be set when running in Roby"
	end
	options = { :auto_attributes => true, :lazy_poster_init => true, :constant => false }.merge(options)
	gen_mod = Genom::GenomModule.new(name, options)

	# Check for a module with the same name
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
	    extend ModuleBase
	end

	# Define the runner task
	define_task(rb_mod, 'Runner') do
	    Class.new(RunnerTask) do
		singleton_class.class_eval do
		    define_method(:roby_module) { rb_mod }
		end
		on(:stop) { genom_module.disconnect if genom_module.connected? }
	    end
	end

	gen_mod.request_info.each do |req_name, req_def|
	    define_request(rb_mod, req_name) if req_name == req_def.name
	end

	return rb_mod
    end

    class GenomState < Roby::ExtendedStruct
	attribute(:autoload_path) { Array.new }
	attribute(:uses) { Array.new }
	def uses?(name); uses.include?(name.to_s) end
	def using(*modules)
	    modules.each do |modname| 
		modname = modname.to_s
		::Roby::Genom::GenomModule(modname) 
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

