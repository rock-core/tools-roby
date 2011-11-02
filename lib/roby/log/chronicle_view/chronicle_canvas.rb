require 'utilrb/module/attr_predicate'
require 'roby/distributed/protocol'

require 'roby/log/relations_view/relations_view'

module Roby
    module LogReplay
        class ChronicleViewport < Qt::AbstractScrollArea
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

                pal = Qt::Palette.new(self.palette)
                pal.setColor(Qt::Palette::Background, Qt::Color.new('white'))
                setAutoFillBackground(true);
                setPalette(pal)
            end

            def update(time)
                @current_time = time

                current_tasks = ValueSet.new
                history_widget.history.each_value do |time, snapshot, _|
                    current_tasks |= snapshot.plan.known_tasks
                end
                @current_tasks = current_tasks.sort_by { |t| t.addition_time }

                repaint
            end

            def paintEvent(event)
                return if !current_time
                painter = Qt::Painter.new(self)
                font = painter.font
                font.point_size = 8
                painter.font = font

                fm = Qt::FontMetrics.new(font)
                text_height = fm.height

                half_width = self.geometry.width / 2
                half_time_width = half_width / time_scale
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
                        end_point   = time_scale * ((task.finalization_time || history_widget.time) - current_time) + half_width
                    else
                        state = task.current_display_state(task.history.last.time)
                        if state == :running
                            end_point = time_scale * (history_widget.time - current_time) + half_width
                        else
                            end_point = time_scale * (task.history.last.time - current_time) + half_width
                        end
                    end

                    add_point = time_scale * (task.addition_time - current_time) + half_width
                    if task.start_time
                        start_point = time_scale * (task.start_time - current_time) + half_width
                    end

                    painter.brush = Qt::Brush.new(RelationsDisplay::TASK_BRUSH_COLORS[:pending])
                    painter.pen   = Qt::Pen.new(RelationsDisplay::TASK_PEN_COLORS[:pending])
                    painter.drawRect(add_point, y1, (start_point || end_point) - add_point, task_height)
                    if task.start_time
                        start_point = time_scale * (task.start_time - current_time) + half_width
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
        end

        class Chronicle < Qt::AbstractScrollArea
            attr_reader :history_widget
            attr_reader :chronicle

            def initialize(history, parent)
                super(parent)
                @history_widget = history
                @chronicle = ChronicleViewport.new(history, parent)
                self.viewport = @chronicle

                horizontal_scroll_bar.connect(SIGNAL('valueChanged(int)')) do
                    value = horizontal_scroll_bar.value
                    time = base_time + Float(value) / chronicle.time_scale
                    chronicle.update(time)
                end
                vertical_scroll_bar.connect(SIGNAL('valueChanged(int)')) do
                    value = vertical_scroll_bar.value
                    chronicle.start_line = value
                    chronicle.repaint
                end
            end

            def base_time
                history_widget.start_time
            end

            def update_scroll_ranges
                if base_time
                    horizontal_scroll_bar.setRange(0, chronicle.time_scale * (history_widget.time - base_time))
                end
                vertical_scroll_bar.setRange(0, chronicle.current_tasks.size)
            end

            def update(time)
                horizontal_scroll_bar.value = chronicle.time_scale * (time - base_time)
                update_scroll_ranges
            end

            def paintEvent(event)
                if !chronicle.current_time # never updated, go to the beginning
                    chronicle.update(history_widget.start_time)
                end

                viewport.paintEvent(event)
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
