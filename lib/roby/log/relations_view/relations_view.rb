require 'roby/log/relations_view/relations_view_ui'

class Ui::RelationsView
    def scene; graphics.scene end
    attr_reader :display
    attr_reader :prefixActions

    ZOOM_STEP = 0.25
    def setupUi(relations_display)
	@display   = relations_display
	super(relations_display.main)

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
		    unless obj = relations_display.object_of(item)
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
		    relations_display.set_visibility(obj, false)
		when "Hide children"
		    for child in Roby::TaskStructure.children_of(obj, relations_display.enabled_relations)
			relations_display.set_visibility(child, false)
		    end
		when "Show children"
		    for child in Roby::TaskStructure.children_of(obj, relations_display.enabled_relations)
			relations_display.set_visibility(child, true)
		    end
		end

		relations_display.update
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
