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
                @pixel_to_time =
                    if new_value < 0
                        new_value.abs
                    else 1.0 / new_value
                    end

                @time_to_pixel =
                    if new_value > 0
                        new_value
                    else 1.0 / new_value.abs
                    end

                update_scroll_ranges
                invalidate_layout_cache
                invalidate_current_tasks
                update
            end

            # Scale factor to convert seconds to pixels
            #
            #   pixels = time_to_pixel * time
            attr_reader :time_to_pixel

            # Scale factor to convert seconds to pixels
            #
            #   pixel = time_to_pixel * time
            attr_reader :pixel_to_time

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
            attr_reader :scheduler_state
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

            # Per-task visual layout information
            #
            # @return [Hash<Task,TaskLayout>]
            attr_reader :layout_cache

            # Per-task messages to be displayed
            attr_reader :messages_per_task

            # @api private
            #
            # Clears {#layout_cache} because parameters changed that require to
            # recompute the task layouts
            def invalidate_layout_cache
                layout_cache.clear
            end

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

                @layout_cache = Hash.new
                @messages_per_task = Hash.new { |h, k| h[k] = Array.new }
                @current_tasks = Array.new
                @current_tasks_dirty = true
                self.time_scale = 10
                @task_height = 10
                @task_separation = 10
                @live_update_margin = 10
                @start_line = 0
                @all_tasks = Set.new
                @all_job_info = Hash.new
                @scheduler_state = Schedulers::State.new
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
                    update
                end
            end

            # Signal emitted when the currently displayed time changed. The time
            # is provided as an offset since base_time
            signals 'void timeChanged(float)'

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
                self.scheduler_state = Schedulers::State.new
            end

            def scheduler_state=(state)
                messages_per_task.clear

                state.pending_non_executable_tasks.each do |msg, *args|
                    formatted_msg = Schedulers::State.format_message_into_string(msg, *args)
                    args.each do |obj|
                        if obj.kind_of?(Roby::Task)
                            messages_per_task[obj] << formatted_msg
                        end
                    end
                end

                scheduler_state.non_scheduled_tasks.each do |task, messages|
                    messages_per_task[task].concat(messages.map { |msg, *args| Schedulers::State.format_message_into_string(msg, task, *args) })
                end
                scheduler_state.actions.each do |task, messages|
                    messages_per_task[task].concat(messages.map { |msg, *args| Schedulers::State.format_message_into_string(msg, task, *args) })
                end
                @scheduler_state = state
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
            end

            def remove_tasks(tasks)
                tasks.each do |t|
                    all_tasks.delete(t)
                    all_job_info.delete(t)
                end
            end

            def contents_height
                update_current_tasks

                display_start, display_end = displayed_time_range
                fm = Qt::FontMetrics.new(font)
                height = current_tasks.inject(0) do |h, t|
                    h + lay_out_task(fm, t).height(display_start, display_end)
                end
                height + current_tasks.size * task_separation + timeline_height
            end

            # @api private
            #
            # Updates the start and current time
            def update_time_range(start_time, current_time)
                update_base_time(start_time)
                update_current_time(current_time)
            end

            # @api private
            # Update the time at the start of the chronicle
            def update_base_time(time)
                @base_time = time
                invalidate_current_tasks
                invalidate_layout_cache
            end

            # @api private
            # Update the time at the end of the chronicle
            def update_current_time(time)
                @current_time = time
                if !base_time
                    update_base_time(time)
                end
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
                if !base_time
                    update_base_time(time)
                end

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
                @display_point = Integer(display_point)
                update_displayed_time_range
                invalidate_current_tasks
            end

            def resizeEvent(event)
                if track_current_time?
                    @display_point = event.size.width - live_update_margin
                elsif display_time && current_time
                    update_display_point
                end
                update_displayed_time_range
                invalidate_current_tasks
                event.accept
            end

            def update_displayed_time_range
                if display_time
                    display_point = self.display_point
                    window_width  = viewport.size.width
                    start_time = display_time - display_point * pixel_to_time
                    end_time   = start_time   + window_width * pixel_to_time
                    @displayed_time_range = [start_time, end_time]
                end
            end

            # The range, in absolute time, currently visible in the view
            #
            # @return [(Time,Time),nil] either said range, or nil if nothing has
            #   ever been displayed so far
            attr_reader :displayed_time_range

            def invalidate_current_tasks
                @current_tasks_dirty = true
            end

            def current_tasks_dirty?
                @current_tasks_dirty
            end

            def update_current_tasks(force: false)
                return if !force && !current_tasks_dirty?

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
                vertical_scroll_bar.setRange(0, current_tasks.size)
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

            SCALES = [1, 2, 5, 10, 20, 30, 60, 90, 120, 300, 600, 1200, 1800, 3600]
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
                step_size = SCALES.find do |scale|
                    scale > min_step_size
                end
                step_size ||= SCALES.last
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

            class TaskLayout
                attr_reader :base_time
                attr_reader :time_to_pixel
                attr_reader :fm

                attr_reader :task
                attr_reader :state

                attr_reader :add_point
                attr_reader :start_point
                attr_reader :end_point

                attr_reader :event_height
                attr_reader :event_max_x
                attr_reader :events
                attr_accessor :messages

                attr_reader :base_height

                def initialize(task, base_time, time_to_pixel, fm)
                    @task = task
                    @base_time = base_time
                    @time_to_pixel = time_to_pixel
                    @fm = fm
                    @event_height = [2 * EVENT_CIRCLE_RADIUS, fm.height].max

                    @add_point = time_to_pixel * (task.addition_time - base_time)
                    @history_size = 0
                    @state = :pending
                    @end_time = task.finalization_time
                    @messages = Array.new
                    @events = Array.new
                    @event_max_x = Array.new
                    @base_height = event_height
                    update
                end

                def update
                    history_size = events.size
                    return if task.history.size == history_size

                    last_event = task.last_event
                    if !last_event
                        @state = :pending
                        end_time = task.finalization_time
                    else
                        @state = GUI.task_state_at(task, last_event.time)
                        if state != :running
                            end_time = last_event.time
                        end
                    end

                    if start_time = task.start_time
                        @start_point = time_to_pixel * (start_time - base_time)
                    end
                    if end_time
                        @end_point = time_to_pixel * (end_time - base_time)
                    end

                    task.history[history_size..-1].each do |event|
                        append_event(event, event_height)
                    end
                end

                def append_event(event, event_height)
                    event_x = Integer(time_to_pixel * (event.time - base_time))
                    event_current_level = nil
                    event_max_x.each_with_index do |x, idx|
                        if x < event_x - EVENT_CIRCLE_RADIUS
                            event_current_level = idx
                            break
                        end
                    end
                    event_current_level ||= event_max_x.size

                    event_y = event_current_level * event_height
                    event_max_x[event_current_level] = event_x + 2 * EVENT_CIRCLE_RADIUS + fm.width(event.symbol.to_s)
                    events << [event.time, event_x, event_y, event.symbol.to_s]
                end

                def events_in_range(display_start_time, display_end_time)
                    events.find_all do |time, _|
                        time > display_start_time && time < display_end_time
                    end
                end

                def height(display_start_time, display_end_time)
                    max_event_y = events_in_range(display_start_time, display_end_time).
                        max_by { |_, _, y, _| y } || Array.new
                    max_event_y = max_event_y[2] || 0
                    (max_event_y || 0) + (messages.size + 1) * fm.height
                end
            end

            def lay_out_task(fm, task)
                layout = layout_cache[task] ||= TaskLayout.new(task, base_time, time_to_pixel, fm)
                layout.messages = messages_per_task.fetch(task, Array.new)
                layout.update
                layout
            end

            def paint_tasks(painter, fm, layout, top_y)
                current_point  = Integer((current_time -  base_time) * time_to_pixel)
                display_offset = Integer(display_point - (display_time - base_time) * time_to_pixel)
                display_start_time, display_end_time = displayed_time_range
                view_height = viewport.size.height

                fm = Qt::FontMetrics.new(font)
                text_height  = fm.height
                text_ascent  = fm.ascent
                text_descent = fm.descent

                update_current_tasks
                current_tasks[start_line..-1].each do |task|
                    break if top_y > view_height

                    task_layout = lay_out_task(fm, task)
                    add_point, start_point, end_point =
                        task_layout.add_point, task_layout.start_point, task_layout.end_point
                    state         = task_layout.state
                    task          = task_layout.task
                    event_height  = task_layout.event_height

                    events = task_layout.events_in_range(display_start_time, display_end_time)
                    task_line_height = (events.max_by { |_, _, y, _| y } || Array.new)[2] || 0
                    task_line_height += event_height
                    task_line_height = [task_height, task_line_height].max

                    # Paint the pending stage, i.e. before the task started
                    top_task_line = top_y
                    painter.brush = TASK_BRUSHES[:pending]
                    painter.pen   = TASK_PENS[:pending]
                    painter.drawRect(
                        add_point + display_offset, top_task_line,
                        (start_point || end_point || current_point) - add_point, task_line_height)

                    if start_point
                        painter.brush = TASK_BRUSHES[:running]
                        painter.pen   = TASK_PENS[:running]
                        painter.drawRect(
                            start_point + display_offset, top_task_line,
                            (end_point || current_point) - start_point, task_line_height)

                        if state && state != :running
                            # Final state is shown by "eating" a few pixels at the task
                            painter.brush = TASK_BRUSHES[state]
                            painter.pen   = TASK_PENS[state]
                            painter.drawRect(
                                end_point - 2 + display_offset, top_task_line,
                                4, task_height)
                        end
                    end

                    # Display the emitted events
                    event_baseline = top_task_line + event_height / 2
                    events.each do |_, x, y, text|
                        x += display_offset
                        y += event_baseline
                        painter.brush, painter.pen = EVENT_STYLES[EVENT_CONTROLABLE | EVENT_EMITTED]
                        painter.drawEllipse(Qt::Point.new(x, y),
                                            EVENT_CIRCLE_RADIUS, EVENT_CIRCLE_RADIUS)
                        painter.pen = EVENT_NAME_PEN
                        painter.drawText(Qt::Point.new(x + 2 * EVENT_CIRCLE_RADIUS, y), text)
                    end

                    # Add the title
                    painter.pen = TASK_NAME_PEN
                    title_baseline = top_task_line + task_line_height + fm.ascent
                    painter.drawText(Qt::Point.new(0, title_baseline), task_timeline_title(task))

                    # And finally display associated messages
                    messages_baseline = title_baseline + text_height
                    painter.pen = TASK_MESSAGE_PEN
                    task_layout.messages.each_with_index do |msg|
                        messages_baseline += text_height
                        painter.drawText(Qt::Point.new(TASK_MESSAGE_MARGIN, messages_baseline), msg)
                    end

                    top_y = messages_baseline + text_descent
                end
            end

            TIMELINE_GRAY_PEN = Qt::Pen.new(Qt::Color.new('gray'))
            TIMELINE_BLACK_PEN = Qt::Pen.new(Qt::Color.new('black'))

            def timeline_height
                fm = Qt::FontMetrics.new(font)
                fm.height + fm.descent + TIMELINE_RULER_LINE_LENGTH
            end

            def paintEvent(event)
                return if !display_time

                painter = Qt::Painter.new(viewport)
                font = painter.font
                font.point_size = 8
                painter.font = font

                fm = Qt::FontMetrics.new(font)
                update_current_tasks
                paint_timeline(painter, fm)
                paint_tasks(painter, fm, task_layout, timeline_height)

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

