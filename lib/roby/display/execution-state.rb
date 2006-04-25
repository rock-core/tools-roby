require 'roby/support'
require 'drb'
require 'enumerator'
require 'roby/task'

module Roby
    class ExecutionStateDisplay
	@@service = nil
	def self.service; @@service end
	def self.start_service(uri = 'druby://localhost:10000')
	    read, write = IO.pipe
	    fork do
		begin
		    require 'roby/display/execution-state-server'
		    a = Qt::Application.new( ARGV )

		    display_server = Roby::ExecutionStateDisplayServer.new
		    DRb.start_service(SERVER_URI, display_server)
		    DRb.thread.priority = 1

		    read.close
		    write.write("OK")

		    display_server.show
		    a.setMainWidget( display_server.main )
		    a.exec()
		rescue Exception => e
		    puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
		end
	    end

	    check = read.read(2)
	    if check != "OK"
		raise "failed to start execution state display server"
	    end

	    DRb.start_service

	    # Get the remote object
	    server = DRbObject.new(nil, uri)
	    #@@service = server
	    @@service = ThreadServer.new(server)
	    @@service.thread.priority = -1
	    @@service
	end
    end

    module EventHooks
	def calling(context)
	    super if defined? super
	    if server = ExecutionStateDisplay.service
		server.pending_event Time.now, self
	    end
	end

	def fired(event)
	    super if defined? super
	    if server = ExecutionStateDisplay.service
		server.fired_event Time.now, self, event
	    end
	end

	def signalling(event, to)
	    super if defined? super
	    if server = ExecutionStateDisplay.service
		server.signalling Time.now, event, to
	    end
	end
    end

    class EventGenerator
	include EventHooks
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
	SERVER_URI = 'druby://localhost:9001'
	server = Roby::ExecutionStateDisplay.start_service(SERVER_URI)

	fill(server)
	sleep(10)
    rescue Exception => e
	puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
    end
end

