require 'roby/support'
require 'drb'
require 'enumerator'

module Roby
    class ExecutionStateDisplay
	@@service = nil
	def self.service; @@service end
	def self.start_service(uri = 'druby://localhost:10000')
	    read, write = IO.pipe
	    fork do
		begin
		    require 'roby/display/execution-state-server'
		    GC.disable
		    a = Qt::Application.new( ARGV )

		    display_server = Roby::ExecutionStateDisplayServer.new
		    DRb.start_service(SERVER_URI, display_server)
		    DRb.thread.priority = 1

		    read.close
		    write.write("OK")

		    display_server.show
		    a.setMainWidget( display_server.view )
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
	    @@service = server
	    #@@service = ThreadServer.new(server)
	    #@@service.thread.priority = -1
	    @@service
	end
    end

    module EventHooks
	def calling(context)
	    super if defined? super
	    ExecutionStateDisplay.service.pending_event Time.now, self
	end

	def fired(event)
	    super if defined? super
	    ExecutionStateDisplay.service.fired_event Time.now, self, event
	end

	def signalling(event, to)
	    super if defined? super
	    ExecutionStateDisplay.service.signalling Time.now, event, to
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

    def fill(state_display)
	t1 = TaskMockup.new
	t1.singleton_class.class_eval do
	    def name; "t1" end
	end

	t2 = TaskMockup.new
	t2.singleton_class.class_eval do
	    def name; "t2" end
	end
		
	f = Roby::ForwarderGenerator.new(t1.event(:start), t2.event(:start))

	f.call(nil)
	puts "End"
	sleep(10)
    end

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
    rescue Exception => e
	puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
    end
end

