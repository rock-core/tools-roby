require 'roby'
require 'roby/event_loop'
require 'roby/relations/executed_by'

module ::Roby::Genom
end

require 'genom/module'
require 'genom/environment'

module ::Roby
    module Genom
	module RobyMapping
	    def roby_module;  self.class.roby_module end
	    def genom_module; self.class.roby_module.genom_module end
	    module ClassExtension
		attr_reader :roby_module
		def genom_module; roby_module.genom_module end
	    end
	end
    
        @activities = Hash.new
        class << self
            attr_reader :activities # :nodoc:
        end

        # The event_reader routines will emit +event+ on +request+ when 
        # +activity+ reached the status +status
        RunningActivity = Struct.new(:task, :abort)

        def self.process_request(task, activity, abort_request)
            # Check abort status. This can raise ReplyTimeout, which is
            # the only event we are interested in
            abort_request.try_wait if abort_request

            activity.try_wait # update status
            if !task.running? && activity.reached?(:intermediate)
                task.emit :start
            elsif activity.reached?(:final)
                task.emit :success, activity.output
            end

        rescue ::Genom::ReplyTimeout => e # timeout waiting for reply
            if abort_request
                raise TaskModelViolation, "failed to emit :stop (#{e.message})"
            else
                raise TaskModelViolation, "failed to emit :start (#{e.message})"
            end

        rescue ::Genom::ActivityInterrupt # interrupted
            task.emit :start, nil if !task.running?
            task.emit :interrupted 

        rescue ::Genom::GenomError => e # the request failed
            raise
            if !task.running?
                raise TaskModelViolation, "failed to start the task: #{e.message}"
            else
                task.emit :failed, e.message
            end
        end

        # Register the event processing in Roby event loop
        Roby.event_processing << lambda do 
            activities.each { |a, r| process_request(r.task, a, r.abort) } 
        end

        # Base class for the task models defined
        # for Genom modules requests
        #
        # See Roby::Genom::GenomModule
        class Request < Roby::Task
	    include RobyMapping

            attr_reader :activity
	    class << self
		attr_reader :timeout
	    end

            def initialize(genom_request)
		@request = genom_request
                super()
            end
            
            def start(context = nil)
                args = [context, self.class.timeout].compact
                @activity = @request.call(*args)
                Genom.activities[@activity] = RunningActivity.new(self)
            end
            event :start
            
            event :success, :terminal => true
            event :failed, :terminal => true

            def interrupted(context); Genom.activities[@activity].abort = @activity.abort end
            event :interrupted, :terminal => true

            event :stop
            on(:stop) { |event| Genom.activities.delete(event.task.activity) }

            on :success => :stop
            on :failed => :stop
            on :interrupted => :failed
        end

        # Define a Task model for the given request
        # The new model is a subclass of Roby::Genom::Request
        def self.define_request(rb_mod, rq_name) # :nodoc:
            gen_mod     = rb_mod.genom_module
            klassname   = rq_name.classify
            method_name = gen_mod.request_info[rq_name].request_method

            Roby.debug { "Defining task model #{klassname} for request #{rq_name}" }
            rq_class = rb_mod.define_under(klassname) do
                Class.new(Request) do
		    @roby_module = rb_mod
		    class_attribute :request_method => gen_mod.method(method_name)

                    def initialize
                        super(self.class.request_method)
                    end
                end
            end
            rb_mod.singleton_class.send(:define_method, method_name) { |*args| rq_class.new }
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
        # 
        def self.GenomModule(name)
            gen_mod = ::Genom::GenomModule.new(name, :auto_attributes => true, :lazy_poster_init => true)
            modname = gen_mod.name.classify
            begin
                rb_mod = ::Roby::Genom.const_get(modname)
            rescue NameError
            end

            if rb_mod
                if !rb_mod.is_a?(Module)
                    raise "module #{modname} already defined, but it is not a Ruby module"
                end

                if rb_mod.respond_to?(:genom_module)
                    if rb_mod.genom_module == gen_mod
                        return rb_mod
                    else
                        raise "module #{modname} already defined, but it does not seem to be associated to #{name}"
                    end
                end
                Roby.debug { "Extending #{modname} for genom module #{name}" }
            else
                Roby.debug { "Defining #{modname} for genom module #{name}" }
                rb_mod = ::Roby::Genom.define_under(modname) { Module.new }
            end

            rb_mod.class_eval do
                @genom_module = gen_mod
		@name = "Roby::Genom::#{modname}"
                class << self
                    attr_reader :genom_module, :name
                    def new_task; Runner.new end
                end
            end

            rb_mod.define_under('Runner') do
                Class.new(Roby::Task) do
		    include RobyMapping
		    @roby_module = rb_mod

		    def initialize
			# Make sure there is a init() method defined in the Roby module if there is one in the
			# Genom module
			if !roby_module.respond_to?(:init) && genom_module.respond_to?(:init)
			    init_requests = genom_module.request_info.
				find_all { |rq| rq.init? }.
				map { |rq| rq.name }.
				join(", ")
			    
			    raise ArgumentError, "The Genom module '#{genom_module.name}' defines the following init requests: #{init_requests}. You must define an init method in '#{roby_module.name}' which calls one of these."
			end
			super
		    end

                    def start(context)
                        ::Genom::Runner.environment.start_modules genom_module.name
			if roby_module.respond_to?(:init)
			    roby_module.init 
			end
                        emit :start
                    end
                    event :start

                    def stop(context)
                        ::Genom::Runner.environment.stop_modules genom_module.name
                        emit :stop
                    end
                    event :stop
                end
            end

            gen_mod.request_info.each do |req_name, req_def|
                define_request(rb_mod, req_name) if !req_def.control?
            end

            return rb_mod
        end
        class GenomState < ExtendableStruct
            def using(*modules)
                modules.each { |modname| ::Roby::Genom::GenomModule(modname) }
            end
        end
        State.genom = GenomState.new
    end
end

