require 'Qt4'
require 'roby/app'

require 'roby/log/gui/replay_controls_ui'
require 'roby/log/gui/data_displays'
require 'roby/log/server'

class RemoteStreamListModel < DataStreamListModel
    attr_reader :known_servers
    def initialize(streams)
	super
	@known_servers = []
    end

    # Update the list of available servers and streams
    def update
	Roby::Log::Server.available_servers.each do |server|
	    unless known_servers.find { |str| str.server == server }
		begin
		    known_servers << Roby::Log::Client.new(server)
		rescue DRb::DRbConnError
		end
	    end
	end

	known_servers.delete_if { |s| !s.connected? }

	found_streams = []
	known_servers.delete_if do |server|
	    begin
		server.streams.each do |stream|
		    found_streams << stream
		    unless streams.include?(stream)
			server.subscribe(stream)
			add_new(stream)
		    end
		end
		false
	    rescue DRb::DRbConnError
		s.disconnect
		true
	    end
	end

	(streams - found_streams).each do |s|
	    row = streams.index(s)
	    removeRow(row, Qt::ModelIndex.new)
	end
    end
end

class RuntimeDisplay < Qt::MainWindow
    attr_reader :ui_displays

    attr_reader :streams
    attr_reader :streams_model

    DISPLAY_MINIMUM_DURATION = 5

    def initialize(broadcast, port, period)
	super()

	# Create the vertical layout for this window
	central_widget = Qt::Widget.new(self)
	self.central_widget = central_widget
	layout = Qt::VBoxLayout.new(central_widget)
	layout.spacing = 6
	layout.margin  = 0

	# add GUI for the data streams and display setup
	@streams	= Array.new
	@streams_model  = RemoteStreamListModel.new(streams)
	displays_holder = Qt::Widget.new(central_widget)
	layout.add_widget displays_holder
	@ui_displays = Ui_DataDisplays.new
	ui_displays.setupUi(displays_holder)
	ui_displays.streams.model = streams_model
	ui_displays.add_stream.enabled = false
	ui_displays.remove_stream.enabled = false
	connect(ui_displays.display_add, SIGNAL("clicked()"), self, SLOT("add_display()"))

	# Set up the stream discovery
	Roby::Log::Server.enable_discovery(broadcast, port, period)

	# This timer is used to call Thread.pass ... of course needed or Ruby
	# threads won't be woken up
	Thread.current.priority = -1

	@threads_timer = Qt::Timer.new(self)
	connect(@threads_timer, SIGNAL('timeout()')) do
	    Thread.pass
	end
	@threads_timer.start(50)

	@display_timer = Qt::Timer.new(self)
	connect(@display_timer, SIGNAL('timeout()')) do
	    streams.each do |s|
		s.synchronize do
		    s.display
		end
	    end
	end
	@display_timer.start(5000)

	sleep(0.5)
	streams_model.update

	@discovery_timer = Qt::Timer.new(self)
	connect(@discovery_timer, SIGNAL('timeout()')) do
	    streams_model.update
	end
	@discovery_timer.start(Integer(period * 1000))
    end

    def add_display(kind = nil)
	ui_displays.add_display(streams_model, kind)
    end
    slots 'add_display()'
end

if $0 == __FILE__
    DRb.start_service "druby://:0"
    Roby::Log::Server.logger.level = Logger::DEBUG

    a = Qt::Application.new(ARGV)
    w = RuntimeDisplay.new('localhost', Roby::Log::Server::RING_PORT, 5)
    w.show
    a.exec
end

