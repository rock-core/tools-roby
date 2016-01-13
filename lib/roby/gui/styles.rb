module Roby
    module GUI
	EVENT_CIRCLE_RADIUS = 3
	TASK_EVENT_SPACING  = 5
	DEFAULT_TASK_WIDTH = 20
	DEFAULT_TASK_HEIGHT = 10
	ARROW_COLOR   = Qt::Color.new('black')
	ARROW_OPENING = 30
	ARROW_SIZE    = 10

	TASK_BRUSH_COLORS = {
	    pending:  Qt::Color.new('#6DF3FF'),
	    running:  Qt::Color.new('#B0FFA6'),
	    success:  Qt::Color.new('#E2E2E2'),
	    finished: Qt::Color.new('#E2A8A8'),
	    finalized: Qt::Color.new('#555555')
	}
	TASK_PEN_COLORS = {
	    pending:  Qt::Color.new('#6DF3FF'),
	    running:  Qt::Color.new('#B0FFA6'),
	    success:  Qt::Color.new('#E2E2E2'),
	    finished: Qt::Color.new('#E2A8A8'),
	    finalized: Qt::Color.new('#555555')
	}
	TASK_NAME_COLOR = Qt::Color.new('black')
	TASK_MESSAGE_COLOR = Qt::Color.new('#606060')
        TASK_MESSAGE_MARGIN = 10
	EVENT_NAME_COLOR = Qt::Color.new('black')
	TASK_FONTSIZE = 10

	PENDING_EVENT_COLOR    = 'black' # default color for events
	FIRED_EVENT_COLOR      = 'green'
	EVENT_FONTSIZE = 8

	PLAN_LAYER             = 0
	TASK_LAYER	       = PLAN_LAYER + 20
	EVENT_LAYER	       = PLAN_LAYER + 30
	EVENT_PROPAGATION_LAYER = PLAN_LAYER + 40

	FIND_MARGIN = 10

        EVENT_CALLED  = 1
        EVENT_EMITTED = 2
        EVENT_CALLED_AND_EMITTED = EVENT_CALLED | EVENT_EMITTED

        EVENT_CONTROLABLE = 4
        EVENT_CONTINGENT  = 8
        FAILED_EMISSION   = 16

        EVENT_STYLES = Hash.new
        EVENT_STYLES[EVENT_CONTROLABLE | EVENT_CALLED] =
            [Qt::Brush.new(Qt::Color.new(PENDING_EVENT_COLOR)),
                Qt::Pen.new(Qt::Color.new(PENDING_EVENT_COLOR))]
        EVENT_STYLES[EVENT_CONTROLABLE | EVENT_EMITTED] =
            [Qt::Brush.new(Qt::Color.new(FIRED_EVENT_COLOR)),
                Qt::Pen.new(Qt::Color.new(FIRED_EVENT_COLOR))]
        EVENT_STYLES[EVENT_CONTROLABLE | EVENT_CALLED_AND_EMITTED] =
            [Qt::Brush.new(Qt::Color.new(FIRED_EVENT_COLOR)),
                Qt::Pen.new(Qt::Color.new(PENDING_EVENT_COLOR))]
        EVENT_STYLES[EVENT_CONTINGENT | EVENT_EMITTED] =
            [Qt::Brush.new(Qt::Color.new('white')), Qt::Pen.new(Qt::Color.new(FIRED_EVENT_COLOR))]
        EVENT_STYLES[EVENT_CONTROLABLE | FAILED_EMISSION] =
            [Qt::Brush.new(Qt::Color.new('red')), Qt::Pen.new(Qt::Color.new('red'))]
        EVENT_STYLES[EVENT_CONTINGENT | FAILED_EMISSION] =
            [Qt::Brush.new(Qt::Color.new('red')), Qt::Pen.new(Qt::Color.new('red'))]

        TIMELINE_RULER_LINE_LENGTH = 10
    end
end

