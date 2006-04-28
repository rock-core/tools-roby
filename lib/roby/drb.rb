require 'drb'
require 'roby/support'
require 'roby/task'
require 'roby/event'
require 'roby/plan'

module Roby
    class Task
        include DRbUndumped
    end
    class Event
        include DRbUndumped
    end
    class Plan
        include DRbUndumped
    end

   
    # The DRb server
    class Server
        def initialize(event_loop)
            @event_loop = event_loop
        end
        def insert(task_model_name)
            task_model_name = task_model_name.camelize
            new_task = Roby.const_get(task_kind).new
            
            yield(new_t.ask) if block_given?
            @event_loop.sent_to(@plan, insert, new_task)
            
        end
        def call(task, event, context)
            event_model = task.event_model(event)
            @event_loop.send_to(event_model, :call, task, context)
        end
        def quit
            @event_loop.raise Interrupt
        end
    end

    # The DRb client
    class Client < DRbObject
        def initialize(uri)
            super(nil, uri)
        end
        def quit
            super
        rescue DRb::DRbConnError
        end
    end

    module DRbDisplayServer
	attr_accessor :changed
	def changed?; @changed end
	def changed!; @changed = true end

	def self.DisplayUpdater(display)

	    def demux(commands)
		commands.each do |name, *args| 
		    block = args.pop
		    send(name, *args, &block) 
		end
	    end
	    
	    # Use an anonymous class to avoid requiring 'Qt' in the main code
	    @@updater_klass ||= Class.new(Qt::Object) do
		attr_reader :display
		def initialize(display)
		    super(display.main_window)
		    @display = display
		    @updater = Qt::Timer.new(self, "timer")
		    @updater.connect(@updater, SIGNAL('timeout()'), self, SLOT('update()'))
		    @updater.start(100)
		end

		def update()
		    Thread.pass
		    if !display.main_window.hidden? && display.changed?
			display.canvas.update
			display.changed = false
			@updater.change_interval 0
			sleep 0.1
		    else
			@updater.change_interval 500
		    end
		end
		slots "update()"
	    end

	    @@updater_klass.new(display)
	end

    end
    
    # A remote display server as a standalone Qt application
    class DRbRemoteDisplay
	attr_reader :service
	def start_service(uri)
	    raise RuntimeError, "already started" if @service

	    read, write = IO.pipe
	    fork do
		begin
		    require 'Qt'
		    a = Qt::Application.new( ARGV )

		    server = yield
		    server.extend DRbDisplayServer
		    updater = Roby::DRbDisplayServer.DisplayUpdater(server)

		    DRb.stop_service
		    DRb.start_service(uri, server)
		    DRb.thread.priority = 1

		    read.close
		    write.write("OK")

		    server.main_window.show
		    a.setMainWidget( server.main_window )
		    a.exec()
		    
		rescue Exception => e
		    puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
		end
	    end

	    check = read.read(2)
	    if check != "OK"
		raise "failed to start execution state display server"
	    end

	    DRb.start_service unless DRb.primary_server

	    # Get the remote object
	    server = DRbObject.new(nil, uri)
	    @service = ThreadServer.new(server, true)
	    @service.thread.priority = -1
	    @service
	end
    end
end

