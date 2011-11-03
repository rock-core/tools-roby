require 'utilrb/module/attr_predicate'
require 'roby/distributed/protocol'

require 'roby/log/gui/styles'

module Roby
    module LogReplay
        class Chronicle < Qt::AbstractScrollArea
            attr_reader :history_widget
            attr_accessor :time_scale
            attr_accessor :current_time
            attr_accessor :task_height
            attr_accessor :task_separation
            attr_reader :plans
            attr_accessor :start_line
            attr_reader :current_tasks
            attr_reader :position_to_task

            def initialize(history, parent)
                super(parent)
                @history_widget = history
                @plan = history.current_plan
                @time_scale = 10
                @task_height = 30
                @task_separation = 10
                @start_line = 0
                @current_tasks = Array.new
                @position_to_task = Array.new

                viewport = Qt::Widget.new
                pal = Qt::Palette.new(viewport.palette)
                pal.setColor(Qt::Palette::Background, Qt::Color.new('white'))
                viewport.setAutoFillBackground(true);
                viewport.setPalette(pal)
                self.viewport = viewport

                horizontal_scroll_bar.connect(SIGNAL('valueChanged(int)')) do
                    value = horizontal_scroll_bar.value
                    time = base_time + Float(value) * pixel_to_time
                    update_current_time(time)
                    emit timeChanged(time - base_time)
                    repaint
                end
                vertical_scroll_bar.connect(SIGNAL('valueChanged(int)')) do
                    value = vertical_scroll_bar.value
                    self.start_line = value
                    repaint
                end
            end

            signals 'void timeChanged(float)'

            def pixel_to_time
                if time_scale < 0
                    time_scale.abs
                else 1.0 / time_scale
                end
            end

            def time_to_pixel
                if time_scale > 0
                    time_scale
                else 1.0 / time_scale.abs
                end
            end

            def wheelEvent(event)
                if event.modifiers != Qt::ControlModifier
                    return super
                end

                # See documentation of wheelEvent
                degrees = event.delta / 8.0
                num_steps = degrees / 15

                old = self.time_scale
                self.time_scale += num_steps
                if time_scale == 0
                    if old > 0
                        self.time_scale = -1
                    else
                        self.time_scale = 1
                    end
                end
                update_scroll_ranges
                viewport.repaint
                event.accept
            end

            def update_current_time(time)
                @current_time = time
                current_tasks = ValueSet.new
                history_widget.history.each_value do |time, snapshot, _|
                    current_tasks |= snapshot.plan.known_tasks
                end
                started_tasks, pending_tasks = current_tasks.partition { |t| t.start_time }
                @current_tasks =
                    started_tasks.sort_by { |t| t.start_time }.
                    concat(pending_tasks.sort_by { |t| t.addition_time })
            end

            def update(time)
                update_scroll_ranges
                horizontal_scroll_bar.value = time_to_pixel * (time - base_time)
            end

            def paintEvent(event)
                if !current_time
                    if history_widget.start_time
                        update_current_time(history_widget.start_time)
                    end
                end

                painter = Qt::Painter.new(viewport)
                font = painter.font
                font.point_size = 8
                painter.font = font

                fm = Qt::FontMetrics.new(font)
                text_height = fm.height

                half_width = self.geometry.width / 2
                half_time_width = half_width * pixel_to_time
                start_time = current_time - half_time_width
                end_time   = history_widget.time + half_time_width

                # Find all running tasks within the display window
                all_tasks = ValueSet.new
                history_widget.history.each_value do |time, snapshot, _|
                    all_tasks |= snapshot.plan.known_tasks
                end

                # Build the timeline
                #
                # First, decide on the scale. We compute a "normal" text width
                # for the time labels, and check what would be a round time-step
                min_step_size = pixel_to_time * 1.5 * fm.width(Roby.format_time(current_time))
                magnitude  = Integer(Math.log10(min_step_size))
                base_value = (min_step_size / 10**magnitude).ceil
                new_value = [1, 2, 5, 10].find { |v| v >= base_value }
                step_size = new_value * 10**magnitude
                # Display the current cycle time
                central_label = Roby.format_time(current_time)
                central_time_min = half_width - fm.width(central_label) / 2
                central_time_max = half_width + fm.width(central_label) / 2
                painter.pen = Qt::Pen.new(Qt::Color.new('gray'))
                painter.drawText(central_time_min, text_height, central_label)
                painter.drawRect(central_time_min - 2, 0, fm.width(central_label) + 4, text_height + 2)
                # Now display. The values are rounded on step_size. If a normal
                # ruler collides with the current time, just ignore it
                painter.pen = Qt::Pen.new(Qt::Color.new('black'))
                step_count = 2 * (half_time_width / min_step_size).ceil
                ruler_base_time = (current_time.to_f / step_size).round * step_size - step_size * step_count / 2
                ruler_base_x = (ruler_base_time - current_time.to_f) * time_to_pixel + half_width
                step_count.times do |i|
                    time = step_size * i + ruler_base_time
                    pos  = step_size * i * time_to_pixel + ruler_base_x
                    time_as_text = Roby.format_time(Time.at(time))
                    min_x = pos - fm.width(time_as_text) / 2
                    max_x = pos + fm.width(time_as_text) / 2
                    if central_time_min > max_x || central_time_max < min_x
                        painter.drawText(min_x, text_height, time_as_text)
                    end
                    painter.drawLine(pos, text_height + fm.descent, pos, text_height + fm.descent + TIMELINE_RULER_LINE_LENGTH)
                end

                y0 = text_height + task_separation
                position_to_task << [y0]
                all_tasks = current_tasks[start_line..-1]
                position_to_task.clear
                all_tasks.each_with_index do |task, idx|
                    line_height = task_height
                    y1 = y0 + task_separation + text_height
                    if y1 > geometry.height
                        break
                    end

                    if task.history.empty?
                        state = :pending
                        end_point   = time_to_pixel * ((task.finalization_time || history_widget.time) - current_time) + half_width
                    else
                        state = task.current_display_state(task.history.last.time)
                        if state == :running
                            end_point = time_to_pixel * (history_widget.time - current_time) + half_width
                        else
                            end_point = time_to_pixel * (task.history.last.time - current_time) + half_width
                        end
                    end

                    add_point = time_to_pixel * (task.addition_time - current_time) + half_width
                    if task.start_time
                        start_point = time_to_pixel * (task.start_time - current_time) + half_width
                    end

                    # Compute the event placement. We do this before the
                    # background, as the event display might make us resize the
                    # line
                    events = []
                    event_base_y = fm.ascent
                    event_height = [2 * EVENT_CIRCLE_RADIUS, text_height].max
                    event_max_x = []
                    task.history.each do |ev|
                        if ev.time > start_time && ev.time < end_time
                            event_x = time_to_pixel * (ev.time - current_time) + half_width

                            event_current_level = nil
                            event_max_x.each_with_index do |x, idx|
                                if x < event_x - EVENT_CIRCLE_RADIUS
                                    event_current_level = idx
                                    break
                                end
                            end
                            event_current_level ||= event_max_x.size

                            event_y = event_base_y + event_current_level * event_height
                            if event_y + event_height + fm.descent > line_height
                                line_height = event_y + event_height + fm.descent
                            end
                            events << [event_x, event_y, ev.symbol.to_s]
                            event_max_x[event_current_level] = event_x + 2 * EVENT_CIRCLE_RADIUS + fm.width(ev.symbol.to_s)
                        end
                    end

                    # Paint the background (i.e. the task state)
                    painter.brush = Qt::Brush.new(TASK_BRUSH_COLORS[:pending])
                    painter.pen   = Qt::Pen.new(TASK_PEN_COLORS[:pending])
                    painter.drawRect(add_point, y1, (start_point || end_point) - add_point, line_height)
                    if task.start_time
                        start_point = time_to_pixel * (task.start_time - current_time) + half_width
                        painter.brush = Qt::Brush.new(TASK_BRUSH_COLORS[:running])
                        painter.pen   = Qt::Pen.new(TASK_PEN_COLORS[:running])
                        painter.drawRect(start_point, y1, end_point - start_point, line_height)
                        if state && state != :running
                            painter.brush = Qt::Brush.new(TASK_BRUSH_COLORS[state])
                            painter.pen   = Qt::Pen.new(TASK_PEN_COLORS[state])
                            painter.drawRect(end_point - 2, y1, 4, task_height)
                        end
                    end

                    # Add the text
                    painter.pen = Qt::Pen.new(TASK_NAME_COLOR)
                    painter.drawText(Qt::Point.new(0, y1 - fm.descent), task.to_s)

                    # And finally display the emitted events
                    events.each do |x, y, text|
                        painter.brush, painter.pen = EVENT_STYLES[EVENT_CONTROLABLE | EVENT_EMITTED]
                        painter.drawEllipse(Qt::Point.new(x, y1 + y),
                                            EVENT_CIRCLE_RADIUS, EVENT_CIRCLE_RADIUS)
                        painter.pen = Qt::Pen.new(EVENT_NAME_COLOR)
                        painter.drawText(Qt::Point.new(x + 2 * EVENT_CIRCLE_RADIUS, y1 + y), text)
                    end

                    y0 = y1 + line_height
                    position_to_task << [y0, task]
                end

                painter.pen = Qt::Pen.new(Qt::Color.new('gray'))
                painter.drawLine(half_width, text_height + 2, half_width, geometry.height)

            ensure
                if painter
                    painter.end
                end
            end

            def base_time
                history_widget.start_time
            end

            def mouseDoubleClickEvent(event)
                _, task = position_to_task.find { |pos, t| pos > event.pos.y }
                if task
                    if !@info_view
                        @info_view = ObjectInfoView.new
                        @info_view.connect(SIGNAL('selectedTime(QDateTime)')) do |t|
                            time = Time.at(Float(t.toMSecsSinceEpoch) / 1000)
                            history_widget.seek(time)
                        end
                    end

                    if @info_view.display(task)
                        @info_view.activate
                    end
                end
                event.accept
            end

            def update_scroll_ranges
                if base_time
                    horizontal_scroll_bar.value = time_to_pixel * (current_time - base_time)
                    horizontal_scroll_bar.setRange(0, time_to_pixel * (history_widget.time - base_time))
                    horizontal_scroll_bar.setPageStep(geometry.width / 4)
                end
                vertical_scroll_bar.setRange(0, current_tasks.size)
            end
        end

        class ChronicleView < PlanView
            def initialize(parent = nil, plan_rebuilder = nil)
                super(parent)
                @layout = Qt::VBoxLayout.new(self)
                @view = Chronicle.new(history_widget, self)
                @layout.add_widget(@view)
                history_widget.add_display(@view)
                history_widget.resize(200, 500)
                history_widget

                resize(500, 500)
            end

            def show
                super
                history_widget.show
            end
        end
    end
end
