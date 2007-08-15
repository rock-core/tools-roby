require 'roby/log/gui/chronicle_view_ui'

class Ui::ChronicleView
    TIME_SCALE_STEP = 2.0
    ZOOM_STEP = 0.25

    attr_reader :display
    def setupUi(display, widget)
	@display = display
	super(widget)

	actionZoom.connect(SIGNAL(:triggered)) do
	    scale = graphics.matrix.m11
	    if scale + ZOOM_STEP > 1
		scale = 1 - ZOOM_STEP
	    end
	    graphics.resetMatrix
	    graphics.scale scale + ZOOM_STEP, scale + ZOOM_STEP
	end
	actionUnZoom.connect(SIGNAL(:triggered)) do
	    scale = graphics.matrix.m11
	    graphics.resetMatrix
	    graphics.scale scale - ZOOM_STEP, scale - ZOOM_STEP
	end
	actionTimeScale.connect(SIGNAL(:triggered)) do
	    current_scale = display.time_scale
	    if current_scale * TIME_SCALE_STEP >= 1000
		display.time_scale = 1000
		actionTimeScale.enabled = false
	    else
		display.time_scale = current_scale * TIME_SCALE_STEP
	    end
	end
	actionTimeUnscale.connect(SIGNAL(:triggered)) do
	    display.time_scale /= TIME_SCALE_STEP
	    actionTimeScale.enabled = true
	end
    end
end

