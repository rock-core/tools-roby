require 'drb'
require 'roby/support'
require 'roby/task'
require 'roby/event'
require 'roby/plan'
require 'facet/kernel/constant'

module Roby::Display
    DEFAULT_REMOTE_DISPLAY_URI = "druby://localhost:10000"

    module DRbDisplayMixin
	attr_accessor :changed
	def changed?; @changed end
	def changed!; @changed = true end

	def update?; @update end
	def disable_updates; @update = false end
	def enable_updates
	    @update = true 
	    changed!
	end

	def update
	    timer_update if respond_to?(:timer_update)
	    canvas.update
	end

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
		    display.enable_updates
		end

		def update?; @update end

		def update
		    Thread.pass

		    return if display.main_window.hidden?
		    return unless display.changed?
		    while @demuxing || display.changed?
			display.changed = false
			Thread.pass
		    end

		    display.update if display.update?
		end
		slots "update()"
	    end

	    @@updater_klass.new(display)
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

	rescue RuntimeError => e
	    Roby.warn "display server #{self} disabled because of exception: #{e.message}(#{e.class})"
	    remote_display.disabled

	    raise ThreadServer::Quit
	end
    end

    class DRbDisplayServer
	attr_reader :displays, :main_window, :tabs
	def initialize(uri)
	    @displays = Hash.new

	    DRb.stop_service
	    DRb.start_service(uri, self)

	    @main_window = Qt::Widget.new
	    main_layout = Qt::VBoxLayout.new(main_window)
	    @tabs = Qt::TabWidget.new(main_window)
	    main_layout.add_widget tabs
	end

	def add(name)
	    # base_widget = Qt::Widget.new(tabs, "tab_#{name}")
	    # layout = Qt::GridLayout.new(base_widget, 1, 1, 11, 6, "layout_#{name}")

	    #display = yield(base_widget)
	    display = yield(tabs)
	    display.extend DRbDisplayMixin
	    display.enable_updates
	    updater = DRbDisplayMixin.DisplayUpdater(display)

	    # layout.add_widget(display.main_window, 0, 0)
	    # tabs.add_tab(base_widget, name.to_s)
	    tabs.add_tab(display.main_window, name.to_s)

	    main_window.resize( Qt::Size.new(600, 480).expandedTo(main_window.minimumSizeHint()) )
	    main_window.hide
	    main_window.show
	end
	private :add

	# Returns a display of the right kind and name. If the display
	# already exists, it is returned. Otherwise, it is created. +kind+
	# can be either 'relations' or 'execution_state'.
	def get(kind, name)
	    kind = kind.to_s

	    unless display = displays[ [kind, name] ]
		begin
		    require "roby/log/#{kind.underscore}/server"
		rescue LoadError
		    require "roby/log/#{kind.underscore.gsub('_', '-')}-server"
		end
		klass_name = "#{kind.classify}Server"
		klass = Roby::Display.constant(klass_name)

		add(name) do |base_widget|
		    display = displays[ [kind, name] ] = klass.new(base_widget)
		end
	    end

	    display

	rescue NameError => e
	    raise unless e.name.to_s == klass_name
	    raise ArgumentError, "no such display type #{klass_name}"
	end

	def delete(display)
	    (k, n), _ = displays.find { |k, d| d == display }
	    return if !k
	    displays.delete( [k, n] )

	    display.main_window.hide
	    tabs.remove_page display.main_window
	end
    end
    
    # A remote display server as a standalone Qt application
    class DRbRemoteDisplay
	# The display server
	attr_reader :display_server
	# The remote display itself
	attr_reader :display
	# The display thread
	attr_reader :display_thread

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

	# Connects to a display server
	# 
	# :start => true if we should start a standalone display, false if we connect to an already existing one
	# :server => uri the URI on which we should connect to the server
	# :server => DRbObject the server object
	def connect(kind, options)
	    raise RuntimeError, "already started" if @display
	    options = validate_options options, :start => false, 
		:server => DEFAULT_REMOTE_DISPLAY_URI, 
		:name => Process.pid.to_s

	    if options[:start]
		read, write = IO.pipe
		fork do
		    read.close
		    standalone(options[:server], kind, options[:name], write)
		end

		write.close
		check = read.read(2)
		if check != "OK"
		    raise RuntimeError, "failed to start #{self.class}"
		end
	    end

	    DRb.start_service unless DRb.primary_server

	    # Get the display server object
	    @display_server = if options[:server].respond_to?(:to_str)
				  DRbObject.new(nil, options[:server].to_str)
			      else options[:server]
			      end

	    @display = display_server.get(kind, options[:name])
	    # Using a ThreadServer allows to multiplex events before sending
	    # them via DRb. As DRb is damn slow, it speeds things a lot
	    @display_thread = DRbDisplayThread.new(self, display, true)

	    self
	end

	def delete
	    display_server.delete(display) if display
	    disabled
	end

	def enable_updates; display_thread.enable_updates end
	def disable_updates(&block)
	    display_thread.disable_updates
	    if block_given?
		begin
		    yield
		ensure
		    enable_updates
		    display_thread.update
		end
	    end
	end

	def disabled
	    @display = nil
	    @display_server = nil
	    @display_thread = nil
	end
	def enabled?; @display end

	def flush; display_thread.flush if display_thread end
    end
end

