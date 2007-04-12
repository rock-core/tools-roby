require 'roby/log/gui/relations_view_ui'

class Ui::RelationsView
    def scene; graphics.scene end

    ZOOM_STEP = 0.25
    def setupUi(widget)
	super

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
	print.connect(SIGNAL(:clicked)) do
	    return unless scene
	    printer = Qt::Printer.new;
	    if Qt::PrintDialog.new(printer).exec() == Qt::Dialog::Accepted
		painter = Qt::Painter.new(printer);
		painter.setRenderHint(Qt::Painter::Antialiasing);
		scene.render(painter);
	    end
	end
    end
end

