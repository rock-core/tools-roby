require 'utilrb/module/attr_predicate'
require 'roby/distributed/protocol'

require 'roby/log/relations_view/relations_view'

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

            def initialize(history, parent)
                super(parent)
                @history_widget = history
                @plan = history.current_plan
                @time_scale = 10
                @task_height = 30
                @task_separation = 10
                @start_line = 0
                @current_tasks = Array.new

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
                    repaint
                end
                vertical_scroll_bar.connect(SIGNAL('valueChanged(int)')) do
                    value = vertical_scroll_bar.value
                    self.start_line = value
                    repaint
                end
            end

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
                if event.modifiers != Qt::NoModifier
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
                viewport.repaint
                event.accept
            end

            def update_current_time(time)
                @current_time = time
                current_tasks = ValueSet.new
                history_widget.history.each_value do |time, snapshot, _|
                    current_tasks |= snapshot.plan.known_tasks
                end
                @current_tasks = current_tasks.sort_by { |t| t.addition_time }
            end

            def update(time)
                horizontal_scroll_bar.value = time_to_pixel * (time - base_time)
                update_scroll_ranges
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

                all_tasks = current_tasks[start_line..-1]
                all_tasks.each_with_index do |task, idx|
                    y0 = (text_height + task_height + task_separation) * idx
                    y1 = y0 + task_separation + text_height

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

                    painter.brush = Qt::Brush.new(RelationsDisplay::TASK_BRUSH_COLORS[:pending])
                    painter.pen   = Qt::Pen.new(RelationsDisplay::TASK_PEN_COLORS[:pending])
                    painter.drawRect(add_point, y1, (start_point || end_point) - add_point, task_height)
                    if task.start_time
                        start_point = time_to_pixel * (task.start_time - current_time) + half_width
                        painter.brush = Qt::Brush.new(RelationsDisplay::TASK_BRUSH_COLORS[:running])
                        painter.pen   = Qt::Pen.new(RelationsDisplay::TASK_PEN_COLORS[:running])
                        painter.drawRect(start_point, y1, end_point - start_point, task_height)
                        if state && state != :running
                            painter.brush = Qt::Brush.new(RelationsDisplay::TASK_BRUSH_COLORS[state])
                            painter.pen   = Qt::Pen.new(RelationsDisplay::TASK_PEN_COLORS[state])
                            painter.drawRect(end_point - 2, y1, 4, task_height)
                        end
                    end

                    painter.pen = Qt::Pen.new(RelationsDisplay::TASK_NAME_COLOR)
                    painter.drawText(Qt::Point.new(0, y1 - fm.descent), task.to_s)
                end

            ensure
                if painter
                    painter.end
                end
            end

            def base_time
                history_widget.start_time
            end

            def update_scroll_ranges
                if base_time
                    horizontal_scroll_bar.setRange(0, time_to_pixel * (history_widget.time - base_time))
                    horizontal_scroll_bar.setPageStep(geometry.width / 4)
                end
                vertical_scroll_bar.setRange(0, current_tasks.size)
            end
        end

        class ChronicleView < RelationsDisplay::PlanView
            def initialize(parent = nil, plan_rebuilder = nil)
                super(parent)
                @layout = Qt::VBoxLayout.new(self)
                @view = Chronicle.new(history_widget, self)
                @layout.add_widget(@view)
                history_widget.add_display(@view)
                history_widget.resize(200, 500)
                history_widget.show

                resize(500, 500)
            end
        end
    end
end
