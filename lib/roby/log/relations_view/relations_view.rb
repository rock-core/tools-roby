require 'roby/log/plan_rebuilder_widget'
require 'roby/log/relations_view/relations_view_ui'
require 'roby/log/relations_view/relations_config'
require 'roby/log/plan_rebuilder'

module Roby
    module LogReplay
        module RelationsDisplay
            class RelationsView < Qt::Widget
                attr_reader :ui

                attr_reader :plan_rebuilder
                attr_reader :history
                attr_reader :canvas
                attr_reader :history_widget

                # In remote connections, this is he period between checking if
                # there is data on the socket, in seconds
                #
                # See #connect
                DEFAULT_REMOTE_POLL_PERIOD = 0.05

                def initialize(parent = nil, plan_rebuilder = nil)
                    super(parent)
                    @ui = Ui::RelationsView.new
                    plan_rebuilder ||= Roby::LogReplay::PlanRebuilder.new
                    @plan_rebuilder = plan_rebuilder
                    ui.setupUi(self)

                    ui.history.setContentsMargins(0, 0, 0, 0)
                    @history_widget_layout = Qt::VBoxLayout.new(ui.history)
                    @history_widget_layout.setContentsMargins(0, 0, 0, 0)
                    @history_widget = PlanRebuilderWidget.new(self, plan_rebuilder)

                    @history_widget.setContentsMargins(0, 0, 0, 0)
                    @history_widget_layout.add_widget(@history_widget)

                    @canvas = RelationsCanvas.new([@history_widget.current_plan])
                    @history_widget.displays << @canvas
                    ui.setupActions(self)
                    ui.graphics.scene = canvas.scene

                    resize 500, 500
                end

                # Opens +filename+ and reads the data from there
                def open(filename)
                    stream = Roby::LogReplay::EventFileStream.open(filename)
                    history_widget.analyze(stream)
                end

                def info(message)
                    ui.info.setText(message)
                end

                def warn(message)
                    ui.info.setText("<font color=\"red\">#{message}</font>")
                end

                # Called when the connection to the log server failed, either
                # because it has been closed or because creating the connection
                # failed
                def connection_failed(e, client, options)
                    @connection_error = e
                    warn("connection failed: #{e.message}")
                    if @reconnection_timer
                        return
                    end

                    @reconnection_timer = Qt::Timer.new(self)
                    @connect_client  = client.dup
                    @connect_options = options.dup
                    @reconnection_timer.connect(SIGNAL('timeout()')) do
                        puts "trying to reconnect to #{@connect_client} #{@connect_options}"
                        if connect(@connect_client, @connect_options)
                            info("Connected")
                            @reconnection_timer.stop
                            @reconnection_timer.dispose
                            @reconnection_timer = nil
                        end
                    end
                    @reconnection_timer.start(1000)
                end

                # Displays the data incoming from +client+
                #
                # +client+ is assumed to be a Roby::Log::Client instance
                #
                # +update_period+ is, in seconds, the period at which the
                # display will check whether there is new data on the port.
                def connect(client, options = Hash.new)
                    options = Kernel.validate_options options,
                        :port => Roby::Log::Server::DEFAULT_PORT,
                        :update_period => DEFAULT_REMOTE_POLL_PERIOD

                    if client.respond_to?(:to_str)
                        begin
                            hostname = client
                            client = Roby::Log::Client.new(client, options[:port])
                        rescue Exception => e
                            connection_failed(e, client, options)
                            return false
                        end
                    end

                    @client = client
                    client.add_listener do |data|
                        history_widget.push_data(data)

                        cycle = plan_rebuilder.cycle_index
                        time = plan_rebuilder.time
                        ui.info.text = "@#{cycle} - #{time.strftime('%H:%M:%S')}.#{'%.03i' % [time.tv_usec / 1000]}"
                    end
                    @connection_pull = timer = Qt::Timer.new(self)
                    timer.connect(SIGNAL('timeout()')) do
                        begin
                            client.read_and_process_pending
                        rescue Exception => e
                            disconnect
                            warn("Disconnected: #{e.message}")
                            puts e.message
                            puts "  " + e.backtrace.join("\n  ")
                            if hostname
                                connect(hostname, options)
                            end
                        end
                    end
                    timer.start(Integer(options[:update_period] * 1000))
                    return true
                end

                def disconnect
                    @client.disconnect
                    @connection_pull.stop
                    @connection_pull.dispose
                    @connection_pull = nil
                end

                # Creates a new display that will display the information
                # present in +filename+
                #
                # +plan_rebuilder+, if given, will be used to rebuild a complete
                # data structure based on the information in +filename+
                def self.from_file(filename, plan_rebuilder = nil)
                    view = new(plan_rebuilder)
                    view.open(filename)
                    view
                end

                def load_options(path)
                    options(YAML.load(File.read(path)))
                end

                def options(new_options = Hash.new)
                    filters = new_options.delete('plan_rebuilder') || Hash.new
                    plan_rebuilder_options = plan_rebuilder.options(filters)

                    options = canvas.options(new_options)
                    if plan_rebuilder_options
                        options['plan_rebuilder'] = plan_rebuilder_options
                    end
                    options
                end
            end
        end
    end
end


class Ui::RelationsView
    def scene; graphics.scene end
    attr_reader :display
    attr_reader :prefixActions

    ZOOM_STEP = 0.25
    def setupActions(view)
	@display   = display = view.canvas

        @actionShowAll = Qt::Action.new(view)
        @actionShowAll.objectName = "actionShowAll"
        @actionShowAll.text = "Show All"
        @actionRedraw = Qt::Action.new(view)
        @actionRedraw.objectName = "actionRedraw"
        @actionRedraw.text = "Redraw"
        @actionZoom = Qt::Action.new(view)
        @actionZoom.objectName = "actionZoom"
        @actionZoom.text = "Zoom +"
        @actionUnzoom = Qt::Action.new(view)
        @actionUnzoom.objectName = "actionUnzoom"
        @actionUnzoom.text = "Zoom -"
        @actionFit = Qt::Action.new(view)
        @actionFit.objectName = "actionFit"
        @actionFit.text = "Fit View"
        @actionOwnership = Qt::Action.new(view)
        @actionOwnership.objectName = "actionOwnership"
        @actionOwnership.text = "Display Ownership"
        @actionOwnership.checkable = true
        @actionOwnership.checked = true
        @actionSVGExport = Qt::Action.new(view)
        @actionSVGExport.objectName = "actionSVGExport"
        @actionSVGExport.text = "SVG Export"
        @actionPrint = Qt::Action.new(view)
        @actionPrint.objectName = "actionPrint"
        @actionPrint.text = "Print"
        @actionKeepSignals = Qt::Action.new(view)
        @actionKeepSignals.objectName = "actionKeepSignals"
        @actionKeepSignals.text = "Keep Signals"
        @actionKeepSignals.checkable = true
        @actionKeepSignals.checked = false
        @actionBookmarksAdd = Qt::Action.new(view)
        @actionBookmarksAdd.objectName = "actionBookmarksAdd"
        @actionBookmarksAdd.text = "Add Bookmark"
        @actionHideFinalized = Qt::Action.new(view)
        @actionHideFinalized.objectName = "actionHideFinalized"
        @actionHideFinalized.text = "Hide Finalized"
        @actionHideFinalized.checkable = true
        @actionHideFinalized.checked = true
        @actionConfigure = Qt::Action.new(view)
        @actionConfigure.objectName = "actionConfigure"
        @actionConfigure.text = "Configure"

        @menubar = Qt::MenuBar.new(view)
        @menubar.objectName = "menubar"
        @menubar.geometry = Qt::Rect.new(0, 0, 800, 21)
        @menuView = Qt::Menu.new("View", @menubar)
        @menuView.objectName = "menuView"

        @menubar.addAction(@menuView.menuAction())
        @menuView.addAction(@actionKeepSignals)
        @menuView.addAction(@actionShowAll)
        @menuView.addSeparator()
        @menuView.addAction(@actionZoom)
        @menuView.addAction(@actionUnzoom)
        @menuView.addAction(@actionFit)
        @menuView.addSeparator()
        @menuView.addAction(@actionSVGExport)
        @menuView.addAction(@actionPrint)
        @menuView.addAction(@actionConfigure)

        @verticalLayout_2.setMenuBar(@menubar)

        @actionConfigure.connect(SIGNAL(:triggered)) do
            if !@configuration_widget
                @configuration_widget = Qt::Widget.new
                @configuration_widget_ui = Ui::RelationsConfig.new(@configuration_widget, display)
            end
            @configuration_widget.show
        end
	
	#############################################################
	# Handle the other toolbar's buttons
	graphics.singleton_class.class_eval do
            define_method(:mouseDoubleClickEvent) do |event|
		item = itemAt(event.pos)
		if item
                    obj = display.object_of(item) ||
                        display.relation_of(item)

		    if !obj
			return super(event)
		    end
		end

                text = []
                if obj.kind_of?(Array)
                    from, to, rel = obj
                    text << "<b>#{rel}</b>"
                    text << "  from: #{from}"
                    text << "  to: #{to}"
                    text << "  info: #{from[to, rel]}"
                elsif obj.kind_of?(Roby::LogReplay::RelationsDisplay::DisplayTask)
                    text << "<b>History</b>"
                    if obj.failed_to_start?
                        text << "Failed to start at #{Roby.format_time(obj.failed_to_start_time)}"
                        text.concat(Roby.format_exception(obj))
                    else
                        obj.history.each do |event| 
                            time = event.time
                            time = "#{time.strftime('%H:%M:%S')}.#{'%.03i' % [time.tv_usec / 1000]}"
                            text << "  #{time}: #{event.symbol}"
                        end
                    end
                end

                if !@textview
                    @textview = Qt::TextEdit.new
                    @textview.resize(200, 400)
                    @textview.readOnly = true
                end
                @textview.windowTitle = "Details for #{obj}"
                @textview.text = text.join("<br>\n")
                @textview.show
            end

	    define_method(:contextMenuEvent) do |event|
		item = itemAt(event.pos)
		if item
		    unless obj = display.object_of(item)
			return super(event)
		    end
		end

		return unless obj.kind_of?(Roby::LogReplay::RelationsDisplay::DisplayTask)

		menu = Qt::Menu.new
		hide_this     = menu.add_action("Hide")
		hide_children = menu.add_action("Hide children")
		show_children = menu.add_action("Show children")
		return unless action = menu.exec(event.globalPos)

		case action.text
		when "Hide"
		    display.selected_objects.delete(obj)
		when "Hide children"
		    for child in Roby::TaskStructure.children_of(obj, display.enabled_relations)
                        display.selected_objects.delete(child)
		    end
		when "Show children"
		    for child in Roby::TaskStructure.children_of(obj, display.enabled_relations)
                        display.selected_objects << child
		    end
		end

		display.update
	    end
	end

	@actionShowAll.connect(SIGNAL(:triggered)) do
	    display.graphics.keys.each do |obj|
		display.set_visibility(obj, true) if obj.kind_of?(Roby::Task::DRoby) || (obj.kind_of?(Roby::EventGenerator::DRoby) && !obj.respond_to?(:task))
	    end
	    display.update
	end

	@actionZoom.connect(SIGNAL(:triggered)) do 
	    scale = graphics.matrix.m11
	    if scale + ZOOM_STEP > 1
		scale = 1 - ZOOM_STEP
	    end
	    graphics.resetMatrix
	    graphics.scale scale + ZOOM_STEP, scale + ZOOM_STEP
	end
	@actionUnzoom.connect(SIGNAL(:triggered)) do
	    scale = graphics.matrix.m11
	    graphics.resetMatrix
	    graphics.scale scale - ZOOM_STEP, scale - ZOOM_STEP
	end
	@actionFit.connect(SIGNAL(:triggered)) do
	    graphics.fitInView(graphics.scene.items_bounding_rect, Qt::KeepAspectRatio)
	end

	@actionKeepSignals.connect(SIGNAL(:triggered)) do 
	    display.keep_signals = @actionKeepSignals.checked?
	end

	@actionPrint.connect(SIGNAL(:triggered)) do
	    return unless scene
	    printer = Qt::Printer.new;
	    if Qt::PrintDialog.new(printer).exec() == Qt::Dialog::Accepted
		painter = Qt::Painter.new(printer);
		painter.setRenderHint(Qt::Painter::Antialiasing);
		scene.render(painter);
	    end
	end

	@actionSVGExport.connect(SIGNAL(:triggered)) do
	    return unless scene

	    if path = Qt::FileDialog.get_save_file_name(nil, "SVG Export")
		svg = Qt::SvgGenerator.new
		svg.file_name = path
		svg.size = Qt::Size.new(Integer(scene.width * 0.8), Integer(scene.height * 0.8))
		painter = Qt::Painter.new
		painter.begin(svg)
		scene.render(painter)
		painter.end
	    end
	end
	@actionSVGExport.enabled = defined?(Qt::SvgGenerator)
    end
end

