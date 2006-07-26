require 'drb'
require 'roby/support'
require 'roby/task'
require 'roby/event'
require 'roby/plan'
require 'facet/kernel/constant'

module Roby
    module DRbDisplayMixin
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

	rescue DRb::DRbConnError, ThreadServer::Quit
	    remote_display.clear!
	    raise ThreadServer::Quit
	end
    end

    class DRbDisplayServer
	attr_reader :displays, :main_window, :tabs
	def initialize(uri)
	    @displays = Hash.new

	    DRb.stop_service
	    DRb.start_service(uri, self)
	    DRb.thread.priority = 1

	    @main_window = Qt::Widget.new
	    main_layout = Qt::VBoxLayout.new(main_window)
	    @tabs = Qt::TabWidget.new(main_window)
	    main_layout.add_widget tabs
	end

	def add(name)
	    base_widget = Qt::Widget.new(tabs, "tab_#{name}")
	    layout = Qt::GridLayout.new(base_widget, 1, 1, 11, 6, "layout_#{name}")

	    display = yield(base_widget)
	    display.extend DRbDisplayMixin
	    updater = Roby::DRbDisplayMixin.DisplayUpdater(display)

	    layout.add_widget(display.main_window, 0, 0)
	    tabs.add_tab(base_widget, name.to_s)

	    main_window.resize( Qt::Size.new(600, 480).expandedTo(main_window.minimumSizeHint()) )
	    main_window.hide
	    main_window.show
	end
	private :add

	def get(kind, name)
	    kind = kind.to_s

	    unless display = displays[ [kind, name] ]
		file_name  = "roby/display/#{kind.underscore}/server"
		klass_name = "#{kind.classify}DisplayServer"

		require file_name
		klass = Roby.constant(klass_name)

		add(kind) do |base_widget|
		    display = displays[ [kind, name] ] = klass.new(base_widget)
		end
	    end

	    display

	rescue NameError => e
	    raise unless e.name.to_s == klass_name
	    raise ArgumentError, "no such display type #{klass_name}"
	end
    end
    
    # A remote display server as a standalone Qt application
    class DRbRemoteDisplay
	attr_reader :service

	# Start the display server in a standalone process
	# and spawn a DRb server to allow connections to it
	#
	# +control_pipe+ can be used to notify a parent process
	# that the initialization has been done properly
	def standalone(uri, kind, name, control_pipe = nil)
	    require 'Qt'
	    a = Qt::Application.new( ARGV )

	    server = DRbDisplayServer.new(uri)
	    display = server.get(kind, name)
	    if control_pipe
		control_pipe.write("OK")
		control_pipe.close
	    end

	    a.setMainWidget( server.main_window )
	    a.exec()

	rescue Exception => e
	    STDERR.puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
	end

	# Log commands instead of sending them to a display server
	def log(logfile)
	    io = File.open(logfile, "w")
	    io.puts self.class.name.gsub(/.*::/, '').to_yaml
	    @service = DRbCommandLogger.new(io)
	end

	# Connects to a display server
	# 
	# :start => uri the URI on which we should start the server
	# :server => uri the URI on which we should connect to the server
	# :server => DRbObject the server object
	def connect(kind, options)
	    raise RuntimeError, "already started" if @service
	    options = validate_options options, [:uri, :server, :replay]

	    parent_pid = Process.pid
	    if options[:uri]
		read, write = IO.pipe
		fork do
		    read.close
		    standalone(options[:uri], kind, parent_pid.to_s, write)
		end

		write.close
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

	    server = server.get(kind, parent_pid.to_s)
	    
	    @service = DRbDisplayThread.new(self, server, true)
	    @service.thread.priority = -1
	    @service
	end

	def clear!
	    @service = nil
	end
    end
end

