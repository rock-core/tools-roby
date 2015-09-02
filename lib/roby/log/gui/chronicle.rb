require 'Qt4'
require 'roby/log/gui/qt4_toMSecsSinceEpoch'
require 'utilrb/module/attr_predicate'
require 'roby/log/gui/styles'
require 'roby/log/gui/object_info_view'

module Roby
    module LogReplay
        # A plan display that puts events and tasks on a timeline
        #
        # The following interactions are available:
        #
        #   * CTRL + wheel: change time scale
        #   * ALT + wheel: horizontal scroll
        #   * wheel: vertical scroll
        #   * double-click: task info view
        #
        class ChronicleWidget < Qt::AbstractScrollArea
            attr_predicate :live?, true
            # True if the time scroll bar is currently pressed
            attr_predicate :horizontal_scroll_bar_down?, true
            # Internal representation of the desired time scale. Don't use it
            # directly, but use #time_to_pixel or #pixel_to_time
            attr_reader :time_scale
            # Change the time scale and update the view
            def time_scale=(new_value)
                @time_scale = new_value
                update_scroll_ranges
                viewport.update
            end
            # How many pixels should there be between the 'now' line and the
            # right side, in pixels
            attr_reader :live_update_margin
            # The point (in pixels) where the current display time should be
            # located on the display
            attr_accessor :display_point
            # The time that is currently at the middle of the view
            attr_accessor :display_time
            # The system's current time
            attr_accessor :current_time
            # The startup time
            attr_accessor :base_time
            # The base height of a task line
            attr_accessor :task_height
            # The separation, in pixels, between tasks
            attr_accessor :task_separation
            # The index of the task that is currently at the top of the view. It
            # is an index in #current_tasks
            attr_accessor :start_line
            # All known tasks
            #
            # @see add_tasks_info remove_tasks
            attr_accessor :all_tasks
            # Job information about all known tasks
            #
            # @see add_tasks_info remove_tasks
            attr_accessor :all_job_info
            # The task layout as computed in the last call to #paintEvent
            attr_reader :task_layout
            # The set of tasks that should currently be managed by the view.
            #
            # It is updated in #update(), i.e. when the view gets something to
            # display
            attr_reader :current_tasks
            # An ordered set of [y, task], where +y+ is the position in Y of the
            # bottom of a task line and +task+ the corresponding task object
            #
            # It is updated on display
            attr_reader :position_to_task
            # The current sorting mode. Can be :start_time or :last_event.
            # Defaults to :start_time
            #
            # In :start mode, the tasks are sorted by the time at which they
            # started. In :last_event, by the time of the last event emitted
            # before the current displayed time: it shows the last active tasks
            # first)
            attr_reader :sort_mode
            # See #sort_mode
            def sort_mode=(mode)
                if ![:start_time, :last_event].include?(mode)
                    raise ArgumentError, "sort_mode can either be :start_time or :last_event, got #{mode}"
                end
                @sort_mode = mode
            end
            # High-level filter on the list of shown tasks. Can either be :all,
            # :running, :current. Defaults to :all
            #
            # In :all mode, all tasks that are included in a plan in a certain
            # point in time are displayed.
            #
            # In :running mode, only the tasks that are running within the
            # display time window are shown.
            #
            # In :current mode, only the tasks that have emitted events within
            # the display time window are shown
            #
            # In :in_range mode, only the tasks that would display something
            # within the display time window are shown
            attr_reader :show_mode

            # See #show_mode
            def show_mode=(mode)
                if ![:all, :running, :current, :in_range].include?(mode)
                    raise ArgumentError, "sort_mode can be :all, :running, :in_range or :current, got #{mode}"
                end
                @show_mode = mode
            end

            # @return [Boolean] true if only the action's toplevel tasks are
            #   shown
            attr_predicate :restrict_to_jobs?

            # Sets whether only the toplevel job tasks should be shown
            def restrict_to_jobs=(set)
                @restrict_to_jobs = set
                setDisplayTime
                update
            end

            # Inclusion filter on task names
            #
            # If it contains a regular expression, only the task names that
            # match the expression will be displayed
            attr_reader :filter

            # Sets the filter regular expression. See #filter
            def filter=(value)
                @filter = value
                setDisplayTime
                update
            end

            # Exclusion filter on task names
            #
            # If it contains a regular expression, the task names that match the
            # expression will not be displayed
            attr_reader :filter_out

            # Sets the filter_out regular expression. See #filter_out
            def filter_out=(value)
                @filter_out = value
                setDisplayTime
                update
            end

            # Display the events "in the future", or stop at the current time.
            # When enabled, a log replay display will look like a live display
            # (use to generate videos for instance)
            attr_predicate :show_future_events?, true

            def initialize(parent = nil)
                super(parent)

                @time_scale = 10
                @task_height = 10
                @task_separation = 10
                @live_update_margin = 10
                @start_line = 0
                @all_tasks = Set.new
                @all_job_info = Hash.new
                @current_tasks = Array.new
                @task_layout = Array.new
                @sort_mode = :start_time
                @show_mode = :all
                @show_future_events = true
                @live = true
                @horizontal_scroll_bar_down = false
                @display_point = viewport.size.width - live_update_margin

                viewport = Qt::Widget.new
                pal = Qt::Palette.new(viewport.palette)
                pal.setColor(Qt::Palette::Background, Qt::Color.new('white'))
                viewport.setAutoFillBackground(true);
                viewport.setPalette(pal)
                self.viewport = viewport

                horizontal_scroll_bar.connect(SIGNAL('sliderMoved(int)')) do
                    value = horizontal_scroll_bar.value
                    self.live = (value == horizontal_scroll_bar.maximum)
                    time = base_time + Float(value) * pixel_to_time
                    update_display_time(time)
                    emit timeChanged(time - base_time)
                end
                horizontal_scroll_bar.connect(SIGNAL('sliderPressed()')) do
                    self.horizontal_scroll_bar_down = true
                end
                horizontal_scroll_bar.connect(SIGNAL('sliderReleased()')) do
                    self.live = (horizontal_scroll_bar.value == horizontal_scroll_bar.maximum)
                    self.horizontal_scroll_bar_down = false
                    update_scroll_ranges
                end
                vertical_scroll_bar.connect(SIGNAL('valueChanged(int)')) do
                    value = vertical_scroll_bar.value
                    self.start_line = value
                    update
                end
            end

            # Signal emitted when the currently displayed time changed. The time
            # is provided as an offset since base_time
            signals 'void timeChanged(float)'

            # Scale factor to convert pixels to seconds
            #
            #   time = pixel_to_time * pixel
            def pixel_to_time
                if time_scale < 0
                    time_scale.abs
                else 1.0 / time_scale
                end
            end

            # Scale factor to convert seconds to pixels
            #
            #   pixel = time_to_pixel * time
            def time_to_pixel
                if time_scale > 0
                    time_scale
                else 1.0 / time_scale.abs
                end
            end

            # Event handler for wheel event
            def wheelEvent(event)
                if event.modifiers != Qt::ControlModifier
                    # Don't let the user scroll with the mouse if vertical
                    # scrolling is off
                    if vertical_scroll_bar_policy == Qt::ScrollBarAlwaysOff
                        event.ignore
                        return
                    else
                        return super
                    end
                end

                # See documentation of wheelEvent
                degrees = event.delta / 8.0
                num_steps = degrees / 15

                old = self.time_scale
                new = old + num_steps
                if new == 0
                    if old > 0
                        self.time_scale = -1
                    else
                        self.time_scale = 1
                    end
                else
                    self.time_scale = new
                end
                event.accept
            end

            def clear_tasks_info
                all_tasks.clear
                all_job_info.clear
                update_current_tasks
            end

            def add_tasks_info(tasks, job_info)
                tasks.each do |t|
                    if base_time && t.addition_time < base_time
                        update_base_time(t.addition_time)
                    end
                end

                all_tasks.merge(tasks)
                all_job_info.merge!(job_info)
                update_current_tasks
            end

            def contents_height
                fm = Qt::FontMetrics.new(font)
                layout = lay_out_tasks_and_events(fm, max_height: nil)
                if layout.empty?
                    0
                else
                    layout.last.top_y + layout.last.height
                end
            end

            def remove_tasks(tasks)
                tasks.each do |t|
                    all_tasks.delete(t)
                    all_job_info.delete(t)
                end
                update_current_tasks
            end

            def update_base_time(time)
                @base_time = time
                update_scroll_ranges
                update
            end

            def update_current_time(time)
                @current_time = time
                update_scroll_ranges
                update
            end

            def update_display_time(time)
                @display_time = time
                _, end_time = displayed_time_range
                limit_end_time = current_time + live_update_margin * pixel_to_time
                update_display_point
                update_scroll_ranges
                update_current_tasks
                update
            end

            def update_display_point
                display_point = viewport.size.width - live_update_margin -
                    (current_time - display_time) * time_to_pixel
                display_point_min = viewport.size.width / 2
                if display_point < display_point_min
                    display_point = display_point_min
                end
                @display_point = display_point
            end

            def resizeEvent(event)
                if live?
                    @display_point = event.size.width - live_update_margin
                elsif display_time && current_time
                    update_display_point
                end

                if current_time && display_time
                    update_current_tasks
                end
                event.accept
            end

            def displayed_time_range
                return if !display_time

                display_point = self.display_point
                window_width  = viewport.size.width
                start_time = display_time - display_point * pixel_to_time
                end_time   = display_time + (window_width - display_point) * pixel_to_time
                return start_time, end_time
            end

            def update_current_tasks
                current_tasks = all_tasks.dup
                if restrict_to_jobs?
                    current_tasks = all_job_info.keys.to_set
                end
                if filter
                    current_tasks = current_tasks.find_all { |t| t.to_s =~ filter }
                end
                if filter_out
                    current_tasks.delete_if { |t| t.to_s =~ filter_out }
                end
                started_tasks, pending_tasks = current_tasks.partition { |t| t.start_time }

                if sort_mode == :last_event
                    not_yet_started, started_tasks = started_tasks.partition { |t| t.start_time > display_time }
                    current_tasks =
                        started_tasks.sort_by do |t|
                            last_event = nil
                            t.history.each do |ev|
                                if ev.time < display_time
                                    last_event = ev
                                else break
                                end
                            end
                            last_event.time
                        end
                    current_tasks = current_tasks.reverse
                    current_tasks.concat(not_yet_started.sort_by { |t| t.start_time })
                    if show_mode == :all
                        current_tasks.
                            concat(pending_tasks.sort_by { |t| t.addition_time })
                    end
                else
                    current_tasks =
                        started_tasks.sort_by { |t| t.start_time }.
                        concat(pending_tasks.sort_by { |t| t.addition_time })
                end

                start_time, end_time = displayed_time_range

                if start_time && (show_mode == :running || show_mode == :current)
                    current_tasks = current_tasks.find_all do |t|
                        (t.start_time && t.start_time < end_time) &&
                            (!t.end_time || t.end_time > start_time)
                    end

                    if show_mode == :current
                        current_tasks = current_tasks.find_all do |t|
                            t.history.any? { |ev| ev.time > start_time && ev.time < end_time }
                        end
                    end
                end

                tasks_in_range, tasks_outside_range =
                    current_tasks.partition do |t|
                        (t.addition_time <= end_time) &&
                            (!t.finalization_time || t.finalization_time >= start_time)
                    end

                if show_mode == :in_range
                    @current_tasks = tasks_in_range
                else
                    @current_tasks = tasks_in_range + tasks_outside_range
                end
            end

            def massage_slot_time_argument(time, default)
                # Convert from QDateTime to allow update() to be a slot
                if time.kind_of?(Qt::DateTime)
                    return Time.at(Float(time.toMSecsSinceEpoch) / 1000)
                elsif !time
                    return default
                else time
                end
            end

            def setDisplayTime(time = nil)
                time = massage_slot_time_argument(time, display_time)
                return if !time

                update_base_time(time) if !base_time
                update_current_time(time) if !current_time
                update_display_time(time)

                if !horizontal_scroll_bar_down?
                    update_scroll_ranges
                    horizontal_scroll_bar.value = time_to_pixel * (display_time - base_time)
                end
            end
            slots 'setDisplayTime(QDateTime)'

            def setCurrentTime(time = nil)
                time = massage_slot_time_argument(time, current_time)
                return if !time

                update_base_time(time) if !base_time
                update_current_time(time)
                update_display_time(time) if !display_time || live?
            end
            slots 'setCurrentTime(QDateTime)'

            def paint_timeline(painter, fm)
                text_height = fm.height
                window_size = viewport.size

                # Display the current cycle time
                central_label = Roby.format_time(display_time)
                central_label_width = fm.width(central_label)
                central_time_max = display_point + central_label_width / 2
                if central_time_max + 3 > window_size.width
                    central_time_max = window_size.width - 3
                end
                central_time_min = central_time_max - central_label_width
                if central_time_min < 3
                    central_time_min = 3
                    central_time_max = central_time_min + central_label_width
                end
                painter.pen = Qt::Pen.new(Qt::Color.new('gray'))
                painter.drawText(central_time_min, text_height, central_label)
                painter.drawRect(central_time_min - 2, 0, central_label_width + 4, text_height + 2)

                # First, decide on the scale. We compute a "normal" text width
                # for the time labels, and check what would be a round time-step
                min_step_size = pixel_to_time * 1.5 * central_label_width
                step_size = [1, 2, 5, 10, 20, 30, 60, 90, 120, 300, 600, 1200, 1800, 3600].find do |scale|
                    scale > min_step_size
                end
                # Now display the timeline itself. If a normal ruler collides
                # with the current time, just ignore it
                start_time, end_time = displayed_time_range
                painter.pen = Qt::Pen.new(Qt::Color.new('black'))
                ruler_base_time = (start_time.to_f / step_size).floor * step_size
                ruler_base_x    = (ruler_base_time - start_time.to_f) * time_to_pixel
                step_count = ((end_time.to_f - ruler_base_time) / step_size).ceil
                step_count.times do |i|
                    time = step_size * i + ruler_base_time
                    pos  = step_size * i * time_to_pixel + ruler_base_x
                    time_as_text = Roby.format_time(Time.at(time))
                    time_as_text_width = fm.width(time_as_text)
                    min_x = pos - time_as_text_width / 2
                    max_x = pos + time_as_text_width / 2
                    if central_time_min > max_x || central_time_max < min_x
                        painter.drawText(min_x, text_height, time_as_text)
                    end
                    painter.drawLine(pos, text_height + fm.descent, pos, text_height + fm.descent + TIMELINE_RULER_LINE_LENGTH)
                end
            end

            def lay_out_events(fm, task, start_time, end_time)
                # Compute the event placement. We do this before the
                # background, as the event display might make us resize the
                # line
                event_base_y = fm.ascent
                event_height = [2 * EVENT_CIRCLE_RADIUS, fm.height].max
                event_max_x = []
                line_height = task_height
                events = task.history.map do |ev|
                    next if ev.time < start_time || ev.time > end_time

                    event_x = time_to_pixel * (ev.time - display_time) + display_point
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
                    event_max_x[event_current_level] = event_x + 2 * EVENT_CIRCLE_RADIUS + fm.width(ev.symbol.to_s)
                    [event_x, event_y, ev.symbol.to_s]
                end.compact
                return events, line_height
            end

            TaskLayout = Struct.new :task, :top_y, :height, :state, :add_point, :start_point, :end_point, :events

            def lay_out_tasks_and_events(fm, max_height: nil)
                current_tasks = self.current_tasks
                return Array.new if current_tasks.empty?

                display_start_time, display_end_time = displayed_time_range

                # Start at the current
                first_index =
                    if start_line >= current_tasks.size
                        current_tasks.size - 1
                    else start_line
                    end
                current_tasks = current_tasks[first_index..-1]
                text_height = fm.height
                bottom_y = task_separation + text_height

                layout = Array.new
                current_tasks.each_with_index do |task, idx|
                    top_y = bottom_y + task_separation + text_height
                    break if max_height && top_y > max_height

                    if task.history.empty?
                        state = :pending
                        end_time = task.finalization_time
                    else
                        state = task.current_display_state(task.history.last.time)
                        if state != :running
                            end_time = task.history.last.time
                        end
                    end
                    add_point = time_to_pixel * (task.addition_time - display_time) + display_point
                    if task.start_time
                        start_point = time_to_pixel * (task.start_time - display_time) + display_point
                    end
                    if end_time
                        end_point = time_to_pixel * (end_time - display_time) + display_point
                    end
                    events, height = lay_out_events(fm, task, display_start_time, display_end_time)

                    bottom_y = top_y + height
                    layout << TaskLayout.new(task, top_y, height, state, add_point, start_point, end_point, events)
                end
                layout
            end


            def paint_tasks(painter, fm, layout)
                current_point = (current_time - display_time) * time_to_pixel + display_point
                layout.each do |task_layout|
                    add_point, start_point, end_point =
                        task_layout.add_point, task_layout.start_point, task_layout.end_point
                    top_y       = task_layout.top_y
                    line_height = task_layout.height
                    state       = task_layout.state
                    task        = task_layout.task

                    # Paint the pending stage, i.e. before the task started
                    painter.brush = Qt::Brush.new(TASK_BRUSH_COLORS[:pending])
                    painter.pen   = Qt::Pen.new(TASK_PEN_COLORS[:pending])
                    painter.drawRect(
                        add_point, top_y,
                        (start_point || end_point || current_point) - add_point, line_height)

                    if start_point
                        painter.brush = Qt::Brush.new(TASK_BRUSH_COLORS[:running])
                        painter.pen   = Qt::Pen.new(TASK_PEN_COLORS[:running])
                        painter.drawRect(
                            start_point, top_y,
                            (end_point || current_point) - start_point, line_height)

                        if state && state != :running
                            # Final state is shown by "eating" a few pixels at the task
                            painter.brush = Qt::Brush.new(TASK_BRUSH_COLORS[state])
                            painter.pen   = Qt::Pen.new(TASK_PEN_COLORS[state])
                            painter.drawRect(end_point - 2, top_y, 4, task_height)
                        end
                    end

                    # Add the text
                    painter.pen = Qt::Pen.new(TASK_NAME_COLOR)
                    painter.drawText(Qt::Point.new(0, top_y - fm.descent), task_timeline_title(task))

                    # And finally display the emitted events
                    task_layout.events.each do |x, y, text|
                        painter.brush, painter.pen = EVENT_STYLES[EVENT_CONTROLABLE | EVENT_EMITTED]
                        painter.drawEllipse(Qt::Point.new(x, top_y + y),
                                            EVENT_CIRCLE_RADIUS, EVENT_CIRCLE_RADIUS)
                        painter.pen = Qt::Pen.new(EVENT_NAME_COLOR)
                        painter.drawText(Qt::Point.new(x + 2 * EVENT_CIRCLE_RADIUS, top_y + y), text)
                    end
                end
            end

            def paintEvent(event)
                return if !display_time

                painter = Qt::Painter.new(viewport)
                font = painter.font
                font.point_size = 8
                painter.font = font

                fm = Qt::FontMetrics.new(font)
                paint_timeline(painter, fm)

                @task_layout = lay_out_tasks_and_events(fm, max_height: size.height)
                paint_tasks(painter, fm, task_layout)

                # Draw the "zero" line
                painter.pen = Qt::Pen.new(Qt::Color.new('gray'))
                painter.drawLine(display_point, fm.height + 2, display_point, size.height)

            ensure
                if painter
                    painter.end
                end
            end

            def task_timeline_title(task)
                text = task.to_s
                if job_task = all_job_info[task]
                    job_text = ["[#{job_task.job_id}]"]
                    if job_task.action_model
                        job_text << job_task.action_model.name.to_s
                    end
                    if job_task.action_arguments
                        job_text << "(" + job_task.action_arguments.map do |k,v|
                            "#{k} => #{v}"
                        end.join(", ") + ")"
                    end
                    text = "#{job_text.join(" ")} / #{text}"
                end
                text
            end

            def clear
                all_tasks.clear
                all_job_info.clear
            end

            def mouseDoubleClickEvent(event)
                click_y = event.pos.y
                layout = task_layout.find { |layout| layout.top_y < click_y && layout.top_y + layout.height > click_y }
                if layout
                    if !@info_view
                        @info_view = ObjectInfoView.new
                        Qt::Object.connect(@info_view, SIGNAL('selectedTime(QDateTime)'),
                                           self, SIGNAL('selectedTime(QDateTime)'))
                    end

                    if @info_view.display(layout.task)
                        @info_view.activate
                    end
                end
                event.accept
            end

            signals 'selectedTime(QDateTime)'

            def update_scroll_ranges
                return if horizontal_scroll_bar_down?

                if base_time && current_time && display_time
                    horizontal_scroll_bar.value = time_to_pixel * (display_time - base_time)
                    horizontal_scroll_bar.setRange(0, time_to_pixel * (current_time - base_time))
                    horizontal_scroll_bar.setPageStep(size.width / 4)
                end
                vertical_scroll_bar.setRange(0, current_tasks.size)
            end
        end

        # The chronicle plan view, including the menu bar and status display
        class ChronicleView < Qt::Widget
            # The underlying ChronicleWidget instance
            attr_reader :chronicle
            # The historyw widget instance
            attr_reader :history_widget

            def initialize(history_widget, parent = nil)
                super(parent)

                @layout = Qt::VBoxLayout.new(self)
                @menu_layout = Qt::HBoxLayout.new
                @layout.add_layout(@menu_layout)
                @history_widget = history_widget
                @chronicle = ChronicleWidget.new(self)
                Qt::Object.connect(@chronicle, SIGNAL('selectedTime(QDateTime)'),
                        history_widget, SLOT('seek(QDateTime)'))
                chronicle.add_tasks_info(*history_widget.tasks_info)
                Qt::Object.connect(history_widget, SIGNAL('addedSnapshot(int)'),
                                  self, SLOT('addedSnapshot(int)'))
                @layout.add_widget(@chronicle)

                # Now setup the menu bar
                @btn_play = Qt::PushButton.new("Play", self)
                @menu_layout.add_widget(@btn_play)
                @btn_play.connect(SIGNAL('clicked()')) do
                    if @play_timer
                        stop
                        @btn_play.text = "Play"
                    else
                        play
                        @btn_play.text = "Stop"
                    end
                end

                @btn_sort = Qt::PushButton.new("Sort", self)
                @menu_layout.add_widget(@btn_sort)
                @btn_sort.menu = sort_options
                @btn_show = Qt::PushButton.new("Show", self)
                @menu_layout.add_widget(@btn_show)
                @btn_show.menu = show_options
                @menu_layout.add_stretch(1)
                @restrict_to_jobs_btn = Qt::CheckBox.new("Restrict to jobs", self)
                @restrict_to_jobs_btn.checkable = true
                @restrict_to_jobs_btn.connect(SIGNAL('toggled(bool)')) do |set|
                    chronicle.restrict_to_jobs = set
                end
                @menu_layout.add_widget(@restrict_to_jobs_btn)

                @filter_lbl = Qt::Label.new("Filter", self)
                @filter_box = Qt::LineEdit.new(self)
                @filter_box.connect(SIGNAL('textChanged(QString const&)')) do |text|
                    if text.empty?
                        chronicle.filter = nil
                    else
                        chronicle.filter = Regexp.new(text.split(' ').join("|"))
                    end
                end
                @menu_layout.add_widget(@filter_lbl)
                @menu_layout.add_widget(@filter_box)
                @filter_out_lbl = Qt::Label.new("Filter out", self)
                @filter_out_box = Qt::LineEdit.new(self)
                @filter_out_box.connect(SIGNAL('textChanged(QString const&)')) do |text|
                    if text.empty?
                        chronicle.filter_out = nil
                    else
                        chronicle.filter_out = Regexp.new(text.split(' ').join("|"))
                    end
                end
                @menu_layout.add_widget(@filter_out_lbl)
                @menu_layout.add_widget(@filter_out_box)
                @menu_layout.add_stretch(1)

                resize(500, 300)
            end

            def addedSnapshot(cycle)
                chronicle.add_tasks_info(*history_widget.tasks_info_of_snapshot(cycle))
            end
            slots 'addedSnapshot(int)'

            def sort_options
                @mnu_sort = Qt::Menu.new(self)
                @actgrp_sort = Qt::ActionGroup.new(@mnu_sort)

                @act_sort = Hash.new
                { "Start time" => :start_time, "Last event" => :last_event }.
                    each do |text, value|
                        act = Qt::Action.new(text, self)
                        act.checkable = true
                        act.connect(SIGNAL('toggled(bool)')) do |onoff|
                            if onoff
                                @chronicle.sort_mode = value
                                @chronicle.update
                            end
                        end
                        @actgrp_sort.add_action(act)
                        @mnu_sort.add_action(act)
                        @act_sort[value] = act
                    end

                @act_sort[:start_time].checked = true
                @mnu_sort
            end

            def show_options
                @mnu_show = Qt::Menu.new(self)
                @actgrp_show = Qt::ActionGroup.new(@mnu_show)

                @act_show = Hash.new
                { "All" => :all, "Running" => :running, "Current" => :current }.
                    each do |text, value|
                        act = Qt::Action.new(text, self)
                        act.checkable = true
                        act.connect(SIGNAL('toggled(bool)')) do |onoff|
                            if onoff
                                @chronicle.show_mode = value
                                @chronicle.setDisplayTime
                            end
                        end
                        @actgrp_show.add_action(act)
                        @mnu_show.add_action(act)
                        @act_show[value] = act
                    end

                @act_show[:all].checked = true
                @mnu_show
            end

            PLAY_STEP = 0.1

            def play
                @play_timer = Qt::Timer.new(self)
                Qt::Object.connect(@play_timer, SIGNAL('timeout()'), self, SLOT('step()'))
                @play_timer.start(Integer(1000 * PLAY_STEP))
            end
            slots 'play()'

            def step
                if chronicle.display_time == chronicle.current_time
                    return
                end

                new_time = chronicle.display_time + PLAY_STEP
                if new_time >= chronicle.current_time
                    new_time = chronicle.current_time
                end
                chronicle.setDisplayTime(new_time)
            end
            slots 'step()'

            def stop
                @play_timer.stop
                @play_timer = nil
            end
            slots 'stop()'

            def updateWindowTitle
                if parent_title = history_widget.window_title
                    self.window_title = parent_title + ": Chronicle"
                else
                    self.window_title = "roby-display: Chronicle"
                end
            end
            slots 'updateWindowTitle()'

            def setDisplayTime(time)
                @chronicle.setDisplayTime(time)
            end
            slots 'setDisplayTime(QDateTime)'

            def setCurrentTime(time)
                @chronicle.setCurrentTime(time)
            end
            slots 'setCurrentTime(QDateTime)'

            # Save view configuration
            def save_options
                result = Hash.new
                result['show_mode'] = chronicle.show_mode
                result['sort_mode'] = chronicle.sort_mode
                result['time_scale'] = chronicle.time_scale
                result['restrict_to_jobs'] = chronicle.restrict_to_jobs?
                result
            end

            # Apply saved configuration
            def apply_options(options)
                if scale = options['time_scale']
                    chronicle.time_scale = scale
                end
                if mode = options['show_mode']
                    @act_show[mode].checked = true
                end
                if mode = options['sort_mode']
                    @act_sort[mode].checked = true
                end
                if mode = options['restrict_to_jobs']
                    @restrict_to_jobs_btn.checked = true
                end
            end
        end
    end
end
