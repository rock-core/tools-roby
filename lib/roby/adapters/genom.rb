require 'roby/state'
require 'roby/support'
require 'roby/event_loop'
require 'roby/base'
require 'roby/task'
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
        # 
        # See Roby::Genom
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
        
        @genom_modules = Hash.new
        
        # Loads a new Genom module and defines the task models for it
        def self.GenomModule(name)
            gen_mod = ::Genom::GenomModule.new(name, :auto_attributes => true, :lazy_poster_init => true)
            modname = gen_mod.name.classify

            Roby.info { "Defining namespace #{modname} for genom module #{name}" }
            rb_mod = Genom.define_under(modname) do 
                Module.new do
                    class << self
                        attr_accessor :module
                    end
                end
            end
            
            rb_mod.module = gen_mod
            gen_mod.request_info.each do |req_name, req_def|
                define_request(rb_mod, req_name) if !req_def.control?
            end

            @genom_modules[name] = rb_mod
        end
        class GenomState < ExtendableStruct
            def dataflow(type, links)
            end
        end
        State.genom = GenomState.new
    end
end

