require 'roby/log/relations_view/relations_view_ui'
require 'roby/log/relations_view/relations_config'
require 'roby/log/plan_rebuilder'

module Roby
    module LogReplay
        module RelationsDisplay
            class RelationsView < Qt::MainWindow
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

                def initialize(plan_rebuilder = nil)
                    super()
                    @ui = Ui::RelationsView.new
                    plan_rebuilder ||= Roby::LogReplay::PlanRebuilder.new
                    @plan_rebuilder = plan_rebuilder
                    @canvas = RelationsCanvas.new(plan_rebuilder.plans)
                    ui.setupUi(self)

                    ui.history.setContentsMargins(0, 0, 0, 0)
                    @history_widget_layout = Qt::VBoxLayout.new(ui.history)
                    @history_widget_layout.setContentsMargins(0, 0, 0, 0)
                    @history_widget = PlanRebuilderWidget.new(self, plan_rebuilder, [canvas])
                    @history_widget.setContentsMargins(0, 0, 0, 0)
                    @history_widget_layout.add_widget(@history_widget)

                    ui.graphics.scene = canvas.scene

                    resize 500, 500
                end

                # Opens +filename+ and reads the data from there
                def open(filename)
                    stream = Roby::LogReplay::EventFileStream.open(filename)
                    history_widget.analyze(stream)
                end

                # Displays the data incoming from +client+
                #
                # +client+ is assumed to be a Roby::Log::Client instance
                #
                # +update_period+ is, in seconds, the period at which the
                # display will check whether there is new data on the port.
                def connect(client, update_period = DEFAULT_REMOTE_POLL_PERIOD)
                    client.add_listener do |data|
                        history_widget.push_data(data)

                        cycle = plan_rebuilder.cycle_index
                        time = plan_rebuilder.time
                        ui.info.text = "@#{cycle} - #{time.strftime('%H:%M:%S')}.#{'%.03i' % [time.tv_usec / 1000]}"
                    end
                    @connection_pull = timer = Qt::Timer.new
                    timer.connect(SIGNAL('timeout()')) do
                        client.read_and_process_pending
                    end
                    timer.start(Integer(update_period * 1000))
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
    def setupUi(view)
	@display   = view.canvas
	super(view)

        actionConfigure.connect(SIGNAL(:triggered)) do
            if !@configuration_widget
                @configuration_widget = Qt::Widget.new
                @configuration_widget_ui = Ui::RelationsConfig.new(@configuration_widget, display)
            end
            @configuration_widget.show
        end
	
	#############################################################
	# Handle the other toolbar's buttons
	graphics.singleton_class.class_eval do
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
		    display.set_visibility(obj, false)
		when "Hide children"
		    for child in Roby::TaskStructure.children_of(obj, display.enabled_relations)
			display.set_visibility(child, false)
		    end
		when "Show children"
		    for child in Roby::TaskStructure.children_of(obj, display.enabled_relations)
			display.set_visibility(child, true)
		    end
		end

		display.update
	    end
	end

	actionShowAll.connect(SIGNAL(:triggered)) do
	    display.graphics.keys.each do |obj|
		display.set_visibility(obj, true) if obj.kind_of?(Roby::Task::DRoby) || (obj.kind_of?(Roby::EventGenerator::DRoby) && !obj.respond_to?(:task))
	    end
	    display.update
	end

	actionZoom.connect(SIGNAL(:triggered)) do 
	    scale = graphics.matrix.m11
	    if scale + ZOOM_STEP > 1
		scale = 1 - ZOOM_STEP
	    end
	    graphics.resetMatrix
	    graphics.scale scale + ZOOM_STEP, scale + ZOOM_STEP
	end
	actionUnzoom.connect(SIGNAL(:triggered)) do
	    scale = graphics.matrix.m11
	    graphics.resetMatrix
	    graphics.scale scale - ZOOM_STEP, scale - ZOOM_STEP
	end
	actionFit.connect(SIGNAL(:triggered)) do
	    graphics.fitInView(graphics.scene.items_bounding_rect, Qt::KeepAspectRatio)
	end

	actionKeepSignals.connect(SIGNAL(:triggered)) do 
	    display.keep_signals = actionKeepSignals.checked?
	end

	actionPrint.connect(SIGNAL(:triggered)) do
	    return unless scene
	    printer = Qt::Printer.new;
	    if Qt::PrintDialog.new(printer).exec() == Qt::Dialog::Accepted
		painter = Qt::Painter.new(printer);
		painter.setRenderHint(Qt::Painter::Antialiasing);
		scene.render(painter);
	    end
	end

	actionSVGExport.connect(SIGNAL(:triggered)) do
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
	actionSVGExport.enabled = defined?(Qt::SvgGenerator)
    end
end

