require 'Qt4'
require 'roby/log/gui/qt4_toMSecsSinceEpoch'
require 'utilrb/module/attr_predicate'
require 'roby/log/gui/styles'

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
            # The PlanRebuilderWidget instance that is managing the history
            attr_reader :history_widget
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
            # The time that is currently at the middle of the view
            attr_accessor :current_time
            # The base height of a task line
            attr_accessor :task_height
            # The separation, in pixels, between tasks
            attr_accessor :task_separation
            # The index of the task that is currently at the top of the view. It
            # is an index in #current_tasks
            attr_accessor :start_line
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
            # Information about the plan's jobs
            #
            # This is updated when {#update_current_time} is called
            #
            # @return [{Task=>Task}] a mapping from job root tasks to the job's
            #   planning task
            attr_reader :job_info
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
            attr_reader :show_mode
            # See #show_mode
            def show_mode=(mode)
                if ![:all, :running, :current].include?(mode)
                    raise ArgumentError, "sort_mode can be :all, :running or :current, got #{mode}"
                end
                @show_mode = mode
            end

            # @return [Boolean] true if only the action's toplevel tasks are
            #   shown
            attr_predicate :restrict_to_jobs?

            # Sets whether only the toplevel job tasks should be shown
            def restrict_to_jobs=(set)
                @restrict_to_jobs = set
                setCurrentTime
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
                setCurrentTime
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
                setCurrentTime
                update
            end

            # Display the events "in the future", or stop at the current time.
            # When enabled, a log replay display will look like a live display
            # (use to generate videos for instance)
            attr_predicate :show_future_events?, true

            def initialize(history_widget, parent = nil)
                super(parent)

                @job_info = Hash.new
                @history_widget = history_widget
                @time_scale = 10
                @task_height = 10
                @task_separation = 10
                @start_line = 0
                @current_tasks = Array.new
                @position_to_task = Array.new
                @sort_mode = :start_time
                @show_mode = :all
                @show_future_events = true
                @live = true
                @horizontal_scroll_bar_down = false

                viewport = Qt::Widget.new
                pal = Qt::Palette.new(viewport.palette)
                pal.setColor(Qt::Palette::Background, Qt::Color.new('white'))
                viewport.setAutoFillBackground(true);
                viewport.setPalette(pal)
                self.viewport = viewport

                updateWindowTitle
                horizontal_scroll_bar.connect(SIGNAL('sliderMoved(int)')) do
                    value = horizontal_scroll_bar.value
                    self.live = (value == horizontal_scroll_bar.maximum)
                    time = base_time + Float(value) * pixel_to_time
                    update_current_time(time)
                    emit timeChanged(time - base_time)
                    update
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

            # Slot used to make the widget update its title when e.g. the
            # underlying history widget changed its source
            def updateWindowTitle
                if parent_title = history_widget.window_title
                    self.window_title = parent_title + ": Chronicle"
                else
                    self.window_title = "roby-display: Chronicle"
                end
            end
            slots 'updateWindowTitle()'

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
                    return super
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

            def update_current_time(time)
                @current_time = time
                current_tasks = ValueSet.new
                job_info.clear

                history_widget.history.each_value do |_, snapshot, _|
                    # We cannot use #planning_task and #planned_task here:
                    # the snapshots are messing with the root graphs.
                    #
                    # We instead have to access the relation graphs stored
                    # in the snapshot
                    snapshot.plan.known_tasks.each do |task|
                        if task.kind_of?(Roby::Interface::Job)
                            planned_task = task.enum_parent_objects(snapshot.relations[Roby::TaskStructure::PlannedBy]).first
                            if planned_task
                                job_info[planned_task] = task
                            end
                        end
                    end
                    if !restrict_to_jobs?
                        current_tasks |= snapshot.plan.known_tasks
                    end
                end
                if restrict_to_jobs?
                    current_tasks = job_info.keys.to_value_set
                end
                if filter
                    current_tasks = current_tasks.find_all { |t| t.to_s =~ filter }
                end
                if filter_out
                    current_tasks.delete_if { |t| t.to_s =~ filter_out }
                end
                started_tasks, pending_tasks = current_tasks.partition { |t| t.start_time }

                if sort_mode == :last_event
                    not_yet_started, started_tasks = started_tasks.partition { |t| t.start_time > current_time }
                    @current_tasks =
                        started_tasks.sort_by do |t|
                            last_event = nil
                            t.history.each do |ev|
                                if ev.time < current_time
                                    last_event = ev
                                else break
                                end
                            end
                            last_event.time
                        end
                    @current_tasks = @current_tasks.reverse
                    @current_tasks.concat(not_yet_started.sort_by { |t| t.start_time })
                else
                    @current_tasks =
                        started_tasks.sort_by { |t| t.start_time }.
                        concat(pending_tasks.sort_by { |t| t.addition_time })
                end

                if show_mode == :all
                    @current_tasks.
                        concat(pending_tasks.sort_by { |t| t.addition_time })
                end
            end

            def setCurrentTime(time = nil)
                # Convert from QDateTime to allow update() to be a slot
                if time.kind_of?(Qt::DateTime)
                    time = Time.at(Float(time.toMSecsSinceEpoch) / 1000)
                elsif !time
                    time = current_time
                end
                return if !time
                update_current_time(time)
                if !horizontal_scroll_bar_down?
                    update_scroll_ranges
                    horizontal_scroll_bar.value = time_to_pixel * (current_time - base_time)
                end
                update
            end
            slots 'setCurrentTime(QDateTime)'

            def live_update(time = nil)
                if live?
                    setCurrentTime(time)
                elsif !horizontal_scroll_bar_down?
                    update_scroll_ranges
                end
                update
            end
            slots 'live_update(QDateTime)'

            def paintEvent(event)
                if !current_time
                    return
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
                end_time   = current_time + half_time_width

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
                position_to_task.clear
                position_to_task << [y0]

                all_tasks = current_tasks
                if show_mode == :running || show_mode == :current
                    all_tasks = all_tasks.find_all do |t|
                        (t.start_time && t.start_time < end_time) &&
                            (!t.end_time || t.end_time > start_time)
                    end

                    if show_mode == :current
                        all_tasks = all_tasks.find_all do |t|
                            t.history.any? { |ev| ev.time > start_time && ev.time < end_time }
                        end
                    end
                end

                # Start at the current
                first_index =
                    if start_line >= all_tasks.size
                        all_tasks.size - 1
                    else start_line
                    end
                return if all_tasks.empty?
                all_tasks = all_tasks[first_index..-1]
                all_tasks.each_with_index do |task, idx|
                    line_height = task_height
                    y1 = y0 + task_separation + text_height
                    if y1 > geometry.height
                        break
                    end

                    if task.history.empty?
                        state = :pending
                        end_point   = time_to_pixel * ((task.finalization_time || history_widget.current_time) - current_time) + half_width
                    else
                        state = task.current_display_state(task.history.last.time)
                        if state == :running
                            end_point = time_to_pixel * (history_widget.current_time - current_time) + half_width
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
                    painter.drawText(Qt::Point.new(0, y1 - fm.descent), task_timeline_title(task))

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

            def task_timeline_title(task)
                text = task.to_s
                if planning_task = job_info[task]
                    job_text = ["[#{planning_task.job_id}]"]
                    if planning_task.action_model
                        job_text << planning_task.action_model.name.to_s
                    end
                    if planning_task.action_arguments
                        job_text << "(" + planning_task.action_arguments.map do |k,v|
                            "#{k} => #{v}"
                        end.join(", ") + ")"
                    end
                    text = "#{job_text.join(" ")} / #{text}"
                end
                text
            end

            # The time of the first registered cycle
            def base_time
                history_widget.start_time
            end

            def mouseDoubleClickEvent(event)
                _, task = position_to_task.find { |pos, t| pos > event.pos.y }
                if task
                    if !@info_view
                        @info_view = ObjectInfoView.new
                        Qt::Object.connect(@info_view, SIGNAL('selectedTime(QDateTime)'),
                            history_widget, SLOT('seek(QDateTime)'))
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
                    horizontal_scroll_bar.setRange(0, time_to_pixel * (history_widget.current_time - base_time))
                    horizontal_scroll_bar.setPageStep(geometry.width / 4)
                end
                vertical_scroll_bar.setRange(0, current_tasks.size)
            end
        end

        # The chronicle plan view, including the menu bar and status display
        class ChronicleView < Qt::Widget
            # The underlying ChronicleWidget instance
            attr_reader :chronicle

            def initialize(history_widget, parent = nil)
                super(parent)

                @layout = Qt::VBoxLayout.new(self)
                @menu_layout = Qt::HBoxLayout.new
                @layout.add_layout(@menu_layout)
                @history_widget = history_widget
                @chronicle = ChronicleWidget.new(history_widget, self)
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
                                @chronicle.setCurrentTime
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
                if chronicle.current_time == chronicle.history_widget.current_time
                    return
                end

                new_time = chronicle.current_time + PLAY_STEP
                if new_time >= chronicle.history_widget.current_time
                    new_time = chronicle.history_widget.current_time
                end
                chronicle.setCurrentTime(new_time)
            end
            slots 'step()'

            def stop
                @play_timer.stop
                @play_timer = nil
            end
            slots 'stop()'

            def updateWindowTitle
                @chronicle.updateWindowTitle
                self.window_title = @chronicle.window_title
            end
            slots 'updateWindowTitle()'

            def setCurrentTime(time)
                @chronicle.setCurrentTime(time)
            end
            slots 'setCurrentTime(QDateTime)'

            def live_update(time)
                @chronicle.live_update(time)
            end
            slots 'live_update(QDateTime)'

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
