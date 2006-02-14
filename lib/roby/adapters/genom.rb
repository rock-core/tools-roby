require 'roby/state'
require 'roby/support'
require 'roby/event_loop'
require 'roby/base'
require 'roby/task'
require 'roby/relations/executed_by'
require 'genom/module'
require 'genom/environment'

module Roby
    module Genom
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
            raise TaskModelViolation, "failed to start the task: #{e.message}"

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
            attr_reader :activity

            def initialize(gen_mod, gen_request)
                @module     = gen_mod
                @request    = gen_request
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
            gen_mod     = rb_mod.module
            klassname   = rq_name.classify
            method_name = gen_mod.request_info[rq_name].request_method

            Roby.info { "Defining task model #{klassname} for request #{rq_name}" }
            rq_class = rb_mod.define_under(klassname) do
                Class.new(Request) do
                    class << self
                        attr_reader :timeout
                    end

                    @module  = gen_mod
                    @request_method = gen_mod.method(method_name)
                    class << self
                        attr_reader :module, :request_method
                    end
                    def initialize
                        super(self.class.module, self.class.request_method)
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
                return ::Roby::Genom.const_get(modname)
            rescue NameError
            end

            Roby.debug { "Defining namespace #{modname} for genom module #{name}" }
            rb_mod = ::Roby::Genom.define_under(modname) do 
                Module.new do
                    @module = gen_mod
                    class << self
                        attr_reader :module
                        def new_task; Runner.new end
                    end
                end
            end

            rb_mod.define_under('Runner') do
                Class.new(Roby::Task) do
                    @module_name = name
                    def self.module_name; @module_name end

                    def start(context)
                        ::Genom::Runner.environment.start_modules self.class.module_name
                        emit :start
                    end
                    event :start

                    def stop(context)
                        ::Genom::Runner.environment.stop_modules self.class.module_name
                        emit :stop
                    end
                    event :stop
                end
            end

            gen_mod.request_info.each do |req_name, req_def|
                define_request(rb_mod, req_name) if !req_def.control?
            end
        end
        class GenomState < ExtendableStruct
            def dataflow(type, links)
            end
        end
        State.genom = GenomState.new
    end
end

