# frozen_string_literal: true

module Roby
    module GUI
        EVENT_CIRCLE_RADIUS = 3
        TASK_EVENT_SPACING  = 5
        DEFAULT_TASK_WIDTH = 20
        DEFAULT_TASK_HEIGHT = 10
        ARROW_COLOR   = Qt::Color.new("black")
        ARROW_OPENING = 30
        ARROW_SIZE    = 10

        TASK_BRUSH_COLORS = {
            pending: Qt::Color.new("#6DF3FF"),
            running: Qt::Color.new("#B0FFA6"),
            success: Qt::Color.new("#E2E2E2"),
            finished: Qt::Color.new("#E2A8A8"),
            finalized: Qt::Color.new("#555555")
        }.freeze
        TASK_BRUSHES =
            TASK_BRUSH_COLORS
            .each_with_object({}) { |(name, color), h| h[name] = Qt::Brush.new(color) }
            .freeze

        TASK_PEN_COLORS = {
            pending: Qt::Color.new("#6DF3FF"),
            running: Qt::Color.new("#B0FFA6"),
            success: Qt::Color.new("#E2E2E2"),
            finished: Qt::Color.new("#E2A8A8"),
            finalized: Qt::Color.new("#555555")
        }.freeze
        TASK_PENS =
            TASK_PEN_COLORS
            .each_with_object({}) { |(name, color), h| h[name] = Qt::Pen.new(color) }
            .freeze

        TASK_NAME_COLOR = Qt::Color.new("black")
        TASK_NAME_PEN = Qt::Pen.new(TASK_NAME_COLOR)
        TASK_MESSAGE_COLOR = Qt::Color.new("#606060")
        TASK_MESSAGE_PEN = Qt::Pen.new(TASK_MESSAGE_COLOR)
        TASK_MESSAGE_MARGIN = 10
        EVENT_NAME_COLOR = Qt::Color.new("black")
        EVENT_NAME_PEN = Qt::Pen.new(EVENT_NAME_COLOR)
        TASK_FONTSIZE = 10

        PENDING_EVENT_COLOR    = "black" # default color for events
        FIRED_EVENT_COLOR      = "green"
        EVENT_FONTSIZE = 8

        PLAN_LAYER             = 0
        TASK_LAYER             = PLAN_LAYER + 20
        EVENT_LAYER            = PLAN_LAYER + 30
        EVENT_PROPAGATION_LAYER = PLAN_LAYER + 40

        FIND_MARGIN = 10

        EVENT_CALLED  = 1
        EVENT_EMITTED = 2
        EVENT_CALLED_AND_EMITTED = EVENT_CALLED | EVENT_EMITTED

        EVENT_CONTROLABLE = 4
        EVENT_CONTINGENT  = 8
        FAILED_EMISSION   = 16

        EVENT_COLORS = {
            (EVENT_CONTROLABLE | EVENT_CALLED) =>
                [PENDING_EVENT_COLOR, PENDING_EVENT_COLOR],
            (EVENT_CONTROLABLE | EVENT_EMITTED) =>
                [FIRED_EVENT_COLOR, FIRED_EVENT_COLOR],
            (EVENT_CONTROLABLE | EVENT_CALLED_AND_EMITTED) =>
                [FIRED_EVENT_COLOR, PENDING_EVENT_COLOR],
            (EVENT_CONTINGENT | EVENT_EMITTED) => ["white", FIRED_EVENT_COLOR],
            (EVENT_CONTROLABLE | FAILED_EMISSION) => %w[red red],
            (EVENT_CONTINGENT | FAILED_EMISSION) => %w[red red]
        }.freeze

        EVENT_STYLES =
            EVENT_COLORS
            .each_with_object({}) do |(flags, colors), h|
                h[flags] = [Qt::Brush.new(Qt::Color.new(colors[0])),
                            Qt::Pen.new(Qt::Color.new(colors[1]))]
            end
            .freeze

        TIMELINE_RULER_LINE_LENGTH = 10
    end
end
