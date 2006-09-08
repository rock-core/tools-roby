require 'roby/log/marshallable'
require 'roby/log/drb'
require 'roby/log/log'

module Roby::Display
    class ExecutionState < DRbRemoteDisplay
	include Singleton

	DEFAULT_URI = 'druby://localhost:10000'

	class << self
	    def service; instance.service end
	    def connect(options = {})
		Roby::Log.loggers << instance
		options[:server] ||= DEFAULT_URI
		instance.connect("execution_state", options)
	    end
	end

	[:generator_calling, :generator_signalling, :generator_fired].each do |m| 
	    define_method(m) { |*args| service.send(m, *args) }
	end

	def disconnect
	    Roby::Log.loggers.delete(service)
	    super
	end
    end
end

if $0 == __FILE__
    STDOUT.sync = true

    TaskMockup = Class.new(Roby::Task) do
	event :start, :command => true
	event :stop
	on :start => :stop
    end

    def task_mockup(name)
	t = TaskMockup.new
	t.model.instance_eval do
	    singleton_class.send(:define_method, :name) { name }
	end

	t
    end

    def fill(state_display)
	t1 = task_mockup("t1")
	t2 = task_mockup("t2")
	t3 = task_mockup("t3")
		
	f = Roby::ForwarderGenerator.new(t1.event(:start), t2.event(:start))
	t1.event(:stop).on t3.event(:start)
	f.call(nil)
	puts "End"
    end

    # Slow down the event propagation so that we see the display being updated
    module SlowEventPropagation
	def calling(context)
	    super if defined? super
	    sleep(0.1)
	end

	def fired(event)
	    super if defined? super
	    sleep(0.1)
	end

	def signalling(event, to)
	    super if defined? super
	    sleep(0.1)
	end
    end
    Roby::EventGenerator.include SlowEventPropagation

    begin
	Thread.abort_on_exception = true
	server = Roby::Display::ExecutionState.connect :start => true

	fill(server)
	sleep(10)
    rescue Exception => e
	puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
    end
end

