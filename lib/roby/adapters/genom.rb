require 'roby/event_loop'
require 'roby/base'
require 'roby/task'
require 'genom/module'
require 'genom/environment'

module Roby
    module Genom
        include ::Genom
        @activities = Array.new
        class << self
            attr_reader :activities # :nodoc:
        end

        # The event_reader routines will emit +event+ on +request+ when 
        # +activity+ reached the status +status
        Running = Struct.new(:request, :abort)

        def self.process_request(request, activity, abort_request)
            # Check abort status. This can raise ReplyTimeout, which is
            # the only event we are interested in
            abort_request.status if abort_request

            task.emit :end, activity.output if !activity.status

        rescue ReplyTimeout => e # timeout waiting for reply
            raise TaskModelViolation, "failed to start the task: #{e.message}"

        rescue ActivityInterrupt # interrupted
            task.emit :start, nil if !task.started?
            task.emit :interrupted 

        rescue GenomError => e # the request failed
            if !task.started?
                raise TaskModelViolation, "failed to start the task: #{e.message}"
            else
                task.emit :failed, e.message
            end
        end

        # Register the event processing in Roby event loop
        Roby.event_processing << lambda do activities.each { |a, r| process_request(r.request, a, r.abort) } end

        # Base class for the task models defined
        # for Genom modules requests
        #
        # 
        # See Roby::Genom
        class Request < Roby::Task
            class << self
                attr_reader :timeout
            end

            def initialize(gen_mod, gen_request)
                @module     = gen_mod
                @request    = gen_request
            end
            
            def start(context)
                @activity = @module.send(@request, context, timeout)
                Genom.requests[@activity] = Running.new(self)
            end
            
            event :success, :terminal => true
            event :failed, :terminal => true
            event :interrupted, :terminal => true
            event :stop, :terminal => true

            on :success => :stop, :failed => :stop, :interrupted => [ :failed, :stop ]

            def stop
                Genom.activities[@activity].abort = @activity.abort
            end
        end

        # Define a Task model for the given request
        # The new model is a subclass of Roby::Genom::Request
        def self.define_request(rb_mod, rq_name) # :nodoc:
            klassname = rq_name.classify
            Roby.info { "Defining task model #{klassname} for request #{rq_name}" }
            rb_mod.define_under(klassname) do
                Class.new(Request) do
                    def initialize
                        super(rb_mod, rb_mod.method(rq_name))
                    end
                end
            end
        end
        
        @genom_modules = Hash.new
        
        # Loads a new Genom module and defines the task models for it
        def self.GenomModule(name)
            gen_mod = GenomModule.new(name, :auto_attributes => true, :lazy_poster_init => true)
            modname = gen_mod.name.classify

            Roby.info { "Defining namespace #{modname} for genom module #{name}" }
            rb_mod = Genom.define_under(modname) do 
                Module.new do
                    class << self
                        # Get the genom module class
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
    end
end

