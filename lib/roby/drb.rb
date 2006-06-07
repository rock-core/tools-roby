require 'drb'
require 'roby/support'
require 'roby/task'
require 'roby/event'
require 'roby/plan'
require 'yaml'

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

	def display(kind, server)
	end
    end

    module DRbDisplayServer
	attr_accessor :changed
	def changed?; @changed end
	def changed!; @changed = true end

	def self.DisplayUpdater(display)
	    def display.demux(commands)
		@demuxing = true
		commands.each do |name, *args| 
		    block = args.pop
		    send(name, *args, &block) 
		end
	    ensure
		@demuxing = false
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
		    return if display.main_window.hidden?
		    Thread.pass
		    return unless display.changed
		    while @demuxing || display.changed
			display.changed = false
			Thread.pass
		    end

		    display.canvas.update
		end
		slots "update()"
	    end

	    @@updater_klass.new(display)
	end

    end

    class DRbCommandLogger
	attr_reader :io
	def initialize(io); @io = io end
	def method_missing(name, *args, &block)
	    raise "no block allowed" if block
	    io.puts [name, *args].to_yaml
	    io.flush
	end
    end

    class DRbDisplayThread < ThreadServer
	attr_reader :remote_display
	def initialize(remote_display, forward_to, multiplex = false)
	    @remote_display = remote_display
	    super(forward_to, multiplex)
	end

	def process_messages
	    super

	rescue DRb::DRbConnError
	    remote_display.clear!
	    raise ThreadServer::Quit
	end
    end
    
    # A remote display server as a standalone Qt application
    class DRbRemoteDisplay
	attr_reader :service

	# Start the display server
	def start_service(uri, control_pipe = nil)
	    require 'Qt'
	    a = Qt::Application.new( ARGV )

	    server = yield
	    server.extend DRbDisplayServer
	    updater = Roby::DRbDisplayServer.DisplayUpdater(server)

	    DRb.stop_service
	    DRb.start_service(uri, server)
	    DRb.thread.priority = 1

	    control_pipe.write("OK") if control_pipe

	    server.main_window.show
	    a.setMainWidget( server.main_window )
	    a.exec()

	rescue Exception => e
	    puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
	end

	# Log commands instead of sending them to a display server
	def log(logfile)
	    io = File.open(logfile, "w")
	    io.puts self.class.name.gsub(/.*::/, '').to_yaml
	    @service = DRbCommandLogger.new(io)
	end

	# Connect to a display server or start it
	# 
	# :start => uri the URI on which we should start the server
	# :server => uri the URI on which we should connect to the server
	# :server => DRbObject the server object
	# :replay => replay a logfile after connection (see #log)
	def connect(options, &init_block)
	    raise RuntimeError, "already started" if @service
	    options = validate_options options, [:uri, :server, :replay]

	    if options[:uri]
		read, write = IO.pipe
		fork do
		    read.close
		    start_service(options[:uri], write, &init_block)
		end

		check = read.read(2)
		if check != "OK"
		    raise RuntimeError, "failed to start execution state display server"
		end

		options[:server] = options[:uri]
	    end

	    DRb.start_service unless DRb.primary_server

	    # Get the display server object
	    server = case options[:server]
		     when DRbObject; options[:server]
		     else; DRbObject.new(nil, options[:server].to_str)
		     end
	    
	    if replay = options[:replay]
		data = File.open(replay) do |io|
		    first_document = true
		    YAML.each_document(io) do |doc|
			# Ignore first document
			if first_document
			    first_document = false
			    next
			end

			server.send(*doc)
		    end
		end
	    end
	    
	    @service = DRbDisplayThread.new(self, server, true)
	    @service.thread.priority = -1
	    @service
	end

	def clear!
	    STDERR.puts "display server has quit"
	    @service = nil
	end
    end
end

