require 'roby/display/marshallable'
require 'roby/display/drb'

module Roby
    class ExecutionStateDisplay < DRbRemoteDisplay
	include Singleton

	DEFAULT_URI = 'druby://localhost:10000'

	class << self
	    def install_hooks; EventGenerator.include EventHooks end


	    def service; instance.service end
	    def log(logfile)
		install_hooks
		instance.log(logfile)
	    end

	    def connect(options = {})
		install_hooks
		instance.connect("execution_state", options)
	    end
	end
	
	module EventHooks
	    def calling(context)
		super if defined? super
		if server = ExecutionStateDisplay.service
		    server.pending_event Time.now, Display::Event[self]
		end
	    end

	    def fired(event)
		super if defined? super
		if server = ExecutionStateDisplay.service
		    server.fired_event Time.now, Display::Event[self], Display::Event[event]
		end
	    end

	    def signalling(event, to)
		super if defined? super
		if server = ExecutionStateDisplay.service
		    server.signalling Time.now, Display::Event[event], Display::Event[to]
		end
	    end
	end

	def postponed(context, wait_for, reason)
	    super if defined? super
	    if server = ExecutionStateDisplay.service
		server.postponed Time.now, self, wait_for, reason
	    end
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
	    singleton_class.class_eval do
		define_method(:name) { name }
	    end
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
	server = Roby::ExecutionStateDisplay.start_service

	fill(server)
	sleep(10)
    rescue Exception => e
	puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
    end
end

