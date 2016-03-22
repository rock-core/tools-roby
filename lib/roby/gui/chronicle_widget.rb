require 'Qt4'
require 'roby/gui/qt4_toMSecsSinceEpoch'
require 'utilrb/module/attr_predicate'
require 'roby/gui/styles'
require 'roby/gui/object_info_view'
require 'roby/gui/task_state_at'

module Roby
    module GUI
        # Widget to display tasks on a chronicle (i.e. timelines)
        #
        # Use {ChronicleView} when using a {PlanRebuilderWidget}
        #
        # The following interactions are available:
        #
        #   * CTRL + wheel: change time scale
        #   * ALT + wheel: horizontal scroll
        #   * wheel: vertical scroll
        #   * double-click: task info view
        #
        class ChronicleWidget < Qt::AbstractScrollArea
            # Whether the widget gets live data in real time
            attr_predicate :live?
            def live=(flag)
                @live = flag
                self.track_current_time = live? && (value == horizontal_scroll_bar.maximum)
            end
            # Whether the widget is currently tracking {#current_time}
            attr_predicate :track_current_time?, true
            # True if the time scroll bar is currently pressed
            attr_predicate :horizontal_scroll_bar_down?, true
            # Internal representation of the desired time scale. Don't use it
            # directly, but use #time_to_pixel or #pixel_to_time
            attr_reader :time_scale
            # Change the time scale and update the view
            def time_scale=(new_value)
                @time_scale = new_value
                update_scroll_ranges
                invalidate_current_tasks
                update
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
            # Scheduler information
            # 
            # @return [Schedulers::State]
            attr_accessor :scheduler_state
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
            # Whether the order defined by {#sort_mode} should be inverted
            def reverse_sort?
                !!@reverse_sort
            end
            # Whether the order defined by {#sort_mode} should be inverted
            def reverse_sort=(flag)
                @reverse_sort = flag
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
                    raise ArgumentError, "show_mode can be :all, :running, :in_range or :current, got #{mode}"
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
                @scheduler_state = Schedulers::State.new
                @current_tasks = Array.new
                @task_layout = Array.new
                @sort_mode = :start_time
                @reverse_sort = false
                @show_mode = :all
                @show_future_events = true
                @live = true
                @track_current_time = true
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
                    self.track_current_time = live? && (value == horizontal_scroll_bar.maximum)
                    time = base_time + Float(value) * pixel_to_time
                    update_display_time(time)
                    emit timeChanged(time - base_time)
                end
                horizontal_scroll_bar.connect(SIGNAL('sliderPressed()')) do
                    self.horizontal_scroll_bar_down = true
                end
                horizontal_scroll_bar.connect(SIGNAL('sliderReleased()')) do
                    self.track_current_time = live? && (horizontal_scroll_bar.value == horizontal_scroll_bar.maximum)
                    self.horizontal_scroll_bar_down = false
                    update_scroll_ranges
                end
                vertical_scroll_bar.connect(SIGNAL('valueChanged(int)')) do
                    value = vertical_scroll_bar.value
                    self.start_line = value
                    invalidate_task_layout
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
                @scheduler_state = Schedulers::State.new
            end

            # Add information to the chronicle for the next display update
            #
            # @param [Array<Roby::Task>] tasks the set of tasks to display
            # @param [Hash<Roby::Task,Roby::Task>] mapping from a placeholder
            #   task and the job task it represents
            # @param [Roby::Schedulers::State] scheduler information to be displayed
            #   on the chronicle
            def add_tasks_info(tasks, job_info)
                tasks.each do |t|
                    if base_time && t.addition_time < base_time
                        update_base_time(t.addition_time)
                    end
                end

                all_tasks.merge(tasks)
                all_job_info.merge!(job_info)
                invalidate_task_layout
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
            end

            # @api private
            # Update the time at the start of the chronicle
            def update_base_time(time)
                @base_time = time
                invalidate_current_tasks
            end

            # @api private
            # Update the time at the end of the chronicle
            def update_current_time(time)
                @current_time = time
                @base_time ||= time
                if !display_time || track_current_time?
                    update_display_time(time)
                else
                    update_scroll_ranges
                    invalidate_current_tasks
                end
            end

            # @api private
            # Update the currently displayed time
            def update_display_time(time)
                @display_time = time
                @base_time ||= time
                _, end_time = displayed_time_range
                update_display_point

                if !horizontal_scroll_bar_down?
                    update_scroll_ranges
                    horizontal_scroll_bar.value = time_to_pixel * (display_time - base_time)
                end

                invalidate_current_tasks
            end

            def update_display_point
                display_point = viewport.size.width - live_update_margin -
                    (current_time - display_time) * time_to_pixel
                display_point_min = viewport.size.width / 2
                if display_point < display_point_min
                    display_point = display_point_min
                end
                @display_point = display_point
                invalidate_current_tasks
            end

            def resizeEvent(event)
                if track_current_time?
                    @display_point = event.size.width - live_update_margin
                elsif display_time && current_time
                    update_display_point
                end
                invalidate_current_tasks
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

            def invalidate_current_tasks
                @current_tasks_dirty = true
                invalidate_task_layout
            end

            def current_tasks_dirty?
                @current_tasks_dirty
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

                if reverse_sort?
                    tasks_in_range = tasks_in_range.reverse
                    tasks_outside_range = tasks_outside_range.reverse
                end

                @current_tasks_dirty = false
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
                update
            end
            slots 'setDisplayTime(QDateTime)'

            def setCurrentTime(time = nil)
                time = massage_slot_time_argument(time, current_time)
                return if !time

                update_base_time(time) if !base_time
                update_current_time(time)
                update
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
                painter.pen = TIMELINE_GRAY_PEN
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
                painter.pen = TIMELINE_BLACK_PEN
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

            TaskLayout = Struct.new :task, :top_y, :events_height, :message_height,
                :state, :add_point, :start_point,
                :end_point, :events, :messages do
                    def height; events_height + message_height end
                end

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

                    last_event = task.last_event
                    if !last_event
                        state = :pending
                        end_time = task.finalization_time
                    else
                        state = GUI.task_state_at(task, last_event.time)
                        if state != :running
                            end_time = last_event.time
                        end
                    end
                    add_point = time_to_pixel * (task.addition_time - display_time) + display_point
                    if task.start_time
                        start_point = time_to_pixel * (task.start_time - display_time) + display_point
                    end
                    if end_time
                        end_point = time_to_pixel * (end_time - display_time) + display_point
                    end
                    events, events_height = lay_out_events(fm, task, display_start_time, display_end_time)

                    messages = Array.new
                    pending = scheduler_state.pending_non_executable_tasks.
                        find_all { |_, *args| args.include?(task) }
                    pending.each do |msg, *args|
                        messages << Schedulers::State.format_message_into_string(msg, *args)
                    end
                    holdoffs = scheduler_state.non_scheduled_tasks.fetch(task, Set.new)
                    holdoffs.each do |msg, *args|
                        messages << Schedulers::State.format_message_into_string(msg, *args)
                    end
                    actions = scheduler_state.actions.fetch(task, Set.new)
                    actions.each do |msg, *args|
                        messages << Schedulers::State.format_message_into_string(msg, *args)
                    end
                    messages_height = text_height * messages.size

                    bottom_y = top_y + events_height + messages_height
                    layout << TaskLayout.new(task, top_y, events_height, messages_height, state, add_point,
                                             start_point, end_point, events, messages)
                end
                layout
            end

            def invalidate_task_layout
                @task_layout_dirty = true
            end

            def task_layout_dirty?
                @task_layout_dirty
            end

            def update_task_layout(metrics: Qt::FontMetrics.new(font))
                @task_layout_dirty = false
                @task_layout = lay_out_tasks_and_events(metrics, max_height: viewport.size.height)
            end

            def paint_tasks(painter, fm, layout)
                current_point = (current_time - display_time) * time_to_pixel + display_point
                layout.each do |task_layout|
                    add_point, start_point, end_point =
                        task_layout.add_point, task_layout.start_point, task_layout.end_point
                    top_y         = task_layout.top_y
                    events_height = task_layout.events_height
                    state         = task_layout.state
                    task          = task_layout.task

                    # Paint the pending stage, i.e. before the task started
                    painter.brush = TASK_BRUSHES[:pending]
                    painter.pen   = TASK_PENS[:pending]
                    painter.drawRect(
                        add_point, top_y,
                        (start_point || end_point || current_point) - add_point, events_height)

                    if start_point
                        painter.brush = TASK_BRUSHES[:running]
                        painter.pen   = TASK_PENS[:running]
                        painter.drawRect(
                            start_point, top_y,
                            (end_point || current_point) - start_point, events_height)

                        if state && state != :running
                            # Final state is shown by "eating" a few pixels at the task
                            painter.brush = TASK_BRUSHES[state]
                            painter.pen   = TASK_PENS[state]
                            painter.drawRect(end_point - 2, top_y, 4, task_height)
                        end
                    end

                    # Add the text
                    painter.pen = TASK_NAME_PEN
                    painter.drawText(Qt::Point.new(0, top_y - fm.descent), task_timeline_title(task))

                    # Display the emitted events
                    task_layout.events.each do |x, y, text|
                        painter.brush, painter.pen = EVENT_STYLES[EVENT_CONTROLABLE | EVENT_EMITTED]
                        painter.drawEllipse(Qt::Point.new(x, top_y + y),
                                            EVENT_CIRCLE_RADIUS, EVENT_CIRCLE_RADIUS)
                        painter.pen = EVENT_NAME_PEN
                        painter.drawText(Qt::Point.new(x + 2 * EVENT_CIRCLE_RADIUS, top_y + y), text)
                    end

                    # And finally display associated messages
                    painter.pen = TASK_MESSAGE_PEN
                    task_layout.messages.each_with_index do |msg, i|
                        y = top_y + task_layout.events_height + fm.height * (i + 1) - fm.descent
                        painter.drawText(Qt::Point.new(TASK_MESSAGE_MARGIN, y), msg)
                    end
                end
            end

            TIMELINE_GRAY_PEN = Qt::Pen.new(Qt::Color.new('gray'))
            TIMELINE_BLACK_PEN = Qt::Pen.new(Qt::Color.new('black'))
            def paintEvent(event)
                return if !display_time

                painter = Qt::Painter.new(viewport)
                font = painter.font
                font.point_size = 8
                painter.font = font

                fm = Qt::FontMetrics.new(font)
                if current_tasks_dirty?
                    update_current_tasks
                    vertical_scroll_bar.setRange(0, current_tasks.size)
                end
                if task_layout_dirty?
                    update_task_layout(metrics: fm)
                end
                paint_timeline(painter, fm)
                paint_tasks(painter, fm, task_layout)

                # Draw the "zero" line
                painter.pen = TIMELINE_GRAY_PEN
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
                vertical_scroll_bar.setRange(0, current_tasks.size)
                return if horizontal_scroll_bar_down?

                if base_time && current_time && display_time
                    horizontal_scroll_bar.value = time_to_pixel * (display_time - base_time)
                    horizontal_scroll_bar.setRange(0, time_to_pixel * (current_time - base_time))
                    horizontal_scroll_bar.setPageStep(size.width / 4)
                end
            end
        end
    end
end

