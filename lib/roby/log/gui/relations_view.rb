require 'roby/log/gui/relations_view_ui'

class Ui::RelationsView
    def scene; graphics.scene end
    attr_reader :display

    ZOOM_STEP = 0.25
    def setupUi(relations_display)
	@display = relations_display
	super(relations_display.main)

	graphics.singleton_class.class_eval do
	    define_method(:contextMenuEvent) do |event|
		item = itemAt(event.pos)
		if item
		    unless obj = relations_display.object_of(item)
			return super(event)
		    end
		end

		return unless obj.kind_of?(Roby::LoggedTask)

		menu = Qt::Menu.new
		hide_this     = menu.add_action("Hide")
		hide_children = menu.add_action("Hide children")
		show_children = menu.add_action("Show children")
		return unless action = menu.exec(event.globalPos)

		case action.text
		when "Hide"
		    relations_display.set_visibility(obj, false)
		when "Hide children"
		    for child in Roby::TaskStructure.children_of(obj)
			relations_display.set_visibility(child, false)
		    end
		when "Show children"
		    for child in Roby::TaskStructure.children_of(obj)
			relations_display.set_visibility(child, true)
		    end
		end

		relations_display.update
	    end
	end

	show_all.connect(SIGNAL(:clicked)) do
	    relations_display.graphics.keys.each do |obj|
		relations_display.set_visibility(obj, true) if obj.kind_of?(Roby::Task)
	    end
	    relations_display.update
	end
	update.connect(SIGNAL(:clicked)) do
	    relations_display.update
	end

	zoom.connect(SIGNAL(:clicked)) do 
	    scale = graphics.matrix.m11
	    if scale + ZOOM_STEP > 1
		scale = 1 - ZOOM_STEP
	    end
	    graphics.resetMatrix
	    graphics.scale scale + ZOOM_STEP, scale + ZOOM_STEP
	end
	unzoom.connect(SIGNAL(:clicked)) do
	    scale = graphics.matrix.m11
	    graphics.resetMatrix
	    graphics.scale scale - ZOOM_STEP, scale - ZOOM_STEP
	end
	fit.connect(SIGNAL(:clicked)) do
	    graphics.fitInView(graphics.scene.items_bounding_rect, Qt::KeepAspectRatio)
	end

	keep_signals.connect(SIGNAL('clicked()')) do 
	    relations_display.keep_signals = keep_signals.checked
	end

	print.connect(SIGNAL(:clicked)) do
	    return unless scene
	    printer = Qt::Printer.new;
	    if Qt::PrintDialog.new(printer).exec() == Qt::Dialog::Accepted
		painter = Qt::Painter.new(printer);
		painter.setRenderHint(Qt::Painter::Antialiasing);
		scene.render(painter);
	    end
	end

	svg.connect(SIGNAL(:clicked)) do
	    return unless scene

	    if path = Qt::FileDialog.get_save_file_name(nil, "SVG Export")
		svg = Qt::SvgGenerator.new
		svg.file_name = path
		painter = Qt::Painter.new
		painter.begin(svg)
		scene.render(painter)
		painter.end
	    end
	end
	svg.enabled = defined?(Qt::SvgGenerator)
    end
end

