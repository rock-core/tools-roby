# frozen_string_literal: true

require "roby/gui/chronicle_widget"

module Roby
    module GUI
        # Integration of a {ChronicleWidget} to use with a {PlanRebuilderWidget}
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
                Qt::Object.connect(@chronicle, SIGNAL("selectedTime(QDateTime)"),
                                   history_widget, SLOT("seek(QDateTime)"))
                chronicle.add_tasks_info(*history_widget.tasks_info)
                Qt::Object.connect(history_widget, SIGNAL("addedSnapshot(int)"),
                                   self, SLOT("addedSnapshot(int)"))
                @layout.add_widget(@chronicle)

                # Now setup the menu bar
                @btn_play = Qt::PushButton.new("Play", self)
                @menu_layout.add_widget(@btn_play)
                @btn_play.connect(SIGNAL("clicked()")) do
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
                @restrict_to_jobs_btn.connect(SIGNAL("toggled(bool)")) do |set|
                    chronicle.restrict_to_jobs = set
                end
                @menu_layout.add_widget(@restrict_to_jobs_btn)

                @filter_lbl = Qt::Label.new("Filter", self)
                @filter_box = Qt::LineEdit.new(self)
                @filter_box.connect(SIGNAL("textChanged(QString const&)")) do |text|
                    if text.empty?
                        chronicle.filter = nil
                    else
                        chronicle.filter = Regexp.new(text.split(" ").join("|"))
                    end
                end
                @menu_layout.add_widget(@filter_lbl)
                @menu_layout.add_widget(@filter_box)
                @filter_out_lbl = Qt::Label.new("Filter out", self)
                @filter_out_box = Qt::LineEdit.new(self)
                @filter_out_box.connect(SIGNAL("textChanged(QString const&)")) do |text|
                    if text.empty?
                        chronicle.filter_out = nil
                    else
                        chronicle.filter_out = Regexp.new(text.split(" ").join("|"))
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
            slots "addedSnapshot(int)"

            def sort_options
                @mnu_sort = Qt::Menu.new(self)
                @actgrp_sort = Qt::ActionGroup.new(@mnu_sort)

                @act_sort = {}
                { "Start time" => :start_time, "Last event" => :last_event }
                    .each do |text, value|
                        act = Qt::Action.new(text, self)
                        act.checkable = true
                        act.connect(SIGNAL("toggled(bool)")) do |onoff|
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

                @act_show = {}
                { "All" => :all, "Running" => :running, "Current" => :current }
                    .each do |text, value|
                        act = Qt::Action.new(text, self)
                        act.checkable = true
                        act.connect(SIGNAL("toggled(bool)")) do |onoff|
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
                Qt::Object.connect(@play_timer, SIGNAL("timeout()"), self, SLOT("step()"))
                @play_timer.start(Integer(1000 * PLAY_STEP))
            end
            slots "play()"

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
            slots "step()"

            def stop
                @play_timer.stop
                @play_timer = nil
            end
            slots "stop()"

            def updateWindowTitle
                if parent_title = history_widget.window_title
                    self.window_title = parent_title + ": Chronicle"
                else
                    self.window_title = "roby-display: Chronicle"
                end
            end
            slots "updateWindowTitle()"

            def update_time_range(start_time, current_time)
                chronicle.update_time_range(start_time, current_time)
            end

            def update_display_time(display_time)
                chronicle.update_display_time(display_time)
            end

            def setDisplayTime(time)
                unless chronicle.base_time
                    chronicle.update_base_time(history_widget.start_time)
                    chronicle.update_current_time(history_widget.current_time)
                end
                @chronicle.setDisplayTime(time)
            end
            slots "setDisplayTime(QDateTime)"

            def setCurrentTime(time)
                unless chronicle.base_time
                    chronicle.update_base_time(history_widget.start_time)
                    chronicle.update_current_time(history_widget.current_time)
                end
                @chronicle.setCurrentTime(time)
            end
            slots "setCurrentTime(QDateTime)"

            # Save view configuration
            def save_options
                result = {}
                result["show_mode"] = chronicle.show_mode
                result["sort_mode"] = chronicle.sort_mode
                result["time_scale"] = chronicle.time_scale
                result["restrict_to_jobs"] = chronicle.restrict_to_jobs?
                result
            end

            # Apply saved configuration
            def apply_options(options)
                if scale = options["time_scale"]
                    chronicle.time_scale = scale
                end
                if mode = options["show_mode"]
                    @act_show[mode].checked = true
                end
                if mode = options["sort_mode"]
                    @act_sort[mode].checked = true
                end
                if mode = options["restrict_to_jobs"]
                    @restrict_to_jobs_btn.checked = true
                end
            end
        end
    end
end
