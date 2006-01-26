require 'roby/base'
require 'roby/task'
require 'genom/module'
require 'genom/environment'

module Roby
    module Genom
        include ::Genom
        @pending = Array.new
        class << self
            attr_reader :pending # :nodoc:
        end

        # Base class for the task models defined
        # for Genom modules requests
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
                context << timeout
                @activity = @module.call(@request, context, timeout)
                Genom.pending[:start] << [self, @activity]
            end
            
            event :success, :terminal => true
            event :failed, :terminal => true
            event :stop, :terminal => true

            on :success, :stop
            def success
            end

            on :failed, :stop
            def failed
            end

            def stop
                Genom.pending[:stop] << [self, @activity.abort]
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

