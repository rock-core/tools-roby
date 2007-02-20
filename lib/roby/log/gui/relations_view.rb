require 'roby/log/gui/relations_view_ui'

class Ui::RelationsView
    attr_reader :scene
    def setupUi(widget)
	super

	zoom.connect(SIGNAL(:clicked)) do 
	    graphics.scale 2.0, 2.0
	end
	unzoom.connect(SIGNAL(:clicked)) do
	    graphics.scale 0.5, 0.5
	end
	fit.connect(SIGNAL(:clicked)) do
	    graphics.fitInView(graphics.scene.items_bounding_rect, Qt::KeepAspectRatio)
	end
    end
end

