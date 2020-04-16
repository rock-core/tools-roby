# frozen_string_literal: true

require "Qt4"
require "roby/gui/plan_rebuilder_widget"
require "roby/gui/relations_view"
require "roby/gui/chronicle_view"

module Roby
    module GUI
        # Main UI for log display
        #
        # It includes
        class LogDisplay < Qt::Widget
            # The PlanRebuilder object that gets the data
            attr_reader :plan_rebuilder
            # The history widget
            attr_reader :history_widget
            # The set of displays that have been created so far
            #
            # It is managed as a mapping from the view class name to an array of
            # views. The array can contain nil elements. This is used to restore
            # configurations across software restarts (i.e. the index is used as
            # an ID for the widget)
            attr_reader :displays
            # The Qt::PushButton object that allows to create new displays
            attr_reader :btn_create_display
            # The label widget that is used to display information/warning
            # messages
            attr_reader :lbl_info
            # The menu button to create new displays
            attr_reader :menu_displays

            class << self
                # Registered plan displays
                #
                # It is a mapping from the displayed name (shown to the users)
                # to the name of the underlying class
                attr_reader :available_displays
            end
            @available_displays =
                { "Relations" => "Roby::GUI::RelationsView",
                  "Chronicle" => "Roby::GUI::ChronicleView" }

            def initialize(parent = nil, plan_rebuilder = nil)
                super

                plan_rebuilder ||= DRoby::PlanRebuilder.new
                @plan_rebuilder = plan_rebuilder

                @displays = Hash.new { |h, k| h[k] = [] }

                @btn_create_display = Qt::PushButton.new("New Display", self)
                @lbl_info = Qt::Label.new(self)
                @history_widget = PlanRebuilderWidget.new(self, plan_rebuilder)
                @layout = Qt::VBoxLayout.new(self)
                @layout.add_widget(@btn_create_display)
                @layout.add_widget(@lbl_info)
                @layout.add_widget(@history_widget)

                Qt::Object.connect(history_widget, SIGNAL("sourceChanged()"),
                                   self, SLOT("updateWindowTitle()"))
                Qt::Object.connect(history_widget, SIGNAL("info(QString)"),
                                   self, SLOT("info(QString)"))
                Qt::Object.connect(history_widget, SIGNAL("warn(QString)"),
                                   self, SLOT("warn(QString)"))

                btn_create_display.text = "New Display"
                @menu_displays = Qt::Menu.new(@btn_create_display)
                self.class.available_displays.each do |name, klass_name|
                    action = menu_displays.addAction(name)
                    action.setData(Qt::Variant.new(klass_name))
                end
                btn_create_display.setMenu(menu_displays)
                menu_displays.connect(SIGNAL("triggered(QAction*)")) do |action|
                    create_display(action.data.toString)
                end

                resize(300, 500)
            end

            def updateWindowTitle
                self.window_title = history_widget.window_title
            end
            slots "updateWindowTitle()"

            def create_all_displays
                self.class.available_displays.each do |user_name, klass_name|
                    create_display(klass_name)
                end
            end

            def allocate_id(klass_name)
                displays[klass_name].size
            end

            def display_from_id(klass_name, id)
                displays[klass_name][id]
            end

            def create_display(name, id = nil)
                # Check whether +klass_name+ is not a user-visible string
                self.class.available_displays.each do |user_name, klass_name|
                    if user_name.downcase == name.downcase
                        name = klass_name
                        break
                    end
                end

                id ||= allocate_id(name)
                if displays[name][id]
                    raise ArgumentError, "there is already a view of type #{name} with ID #{id}"
                end

                klass = begin constant(name)
                        rescue NameError => e
                            Roby.warn "cannot create display of class #{name}: #{e}"
                            return
                        end

                log_display = self
                view = klass.new(@history_widget)
                view.singleton_class.class_eval do
                    define_method :closeEvent do |event|
                        log_display.remove_display(name, id)
                        event.accept
                    end
                end
                if view.respond_to?(:live=)
                    view.live = false
                end
                connect_display(history_widget, view)
                view.setAttribute(Qt::WA_QuitOnClose, false)

                view.show
                displays[name][id] = view
            end

            def remove_display(name, id)
                view = displays[name][id]
                displays[name][id] = nil
                disconnect_display(history_widget, view)
            end

            def connect_display(history_widget, view)
                if history_widget.start_time && history_widget.current_time
                    view.update_time_range(history_widget.start_time, history_widget.current_time)
                    view.update_display_time(history_widget.display_time)
                end
                Qt::Object.connect(history_widget, SIGNAL("appliedSnapshot(QDateTime)"),
                                   view, SLOT("setDisplayTime(QDateTime)"))
                Qt::Object.connect(history_widget, SIGNAL("liveUpdate(QDateTime)"),
                                   view, SLOT("setCurrentTime(QDateTime)"))
                Qt::Object.connect(history_widget, SIGNAL("sourceChanged()"),
                                   view, SLOT("updateWindowTitle()"))
            end

            def disconnect_display(history_widget, view)
                Qt::Object.disconnect(history_widget, SIGNAL("appliedSnapshot(QDateTime)"),
                                      view, SLOT("setDisplayTime(QDateTime)"))
                Qt::Object.disconnect(history_widget, SIGNAL("liveUpdate(QDateTime)"),
                                      view, SLOT("setCurrentTime(QDateTime)"))
                Qt::Object.disconnect(history_widget, SIGNAL("sourceChanged()"),
                                      view, SLOT("updateWindowTitle()"))
            end

            def info(message)
                lbl_info.text = message
            end
            slots "info(QString)"

            def warn(message)
                lbl_info.setText("<font color=\"red\">#{message}</font>")
            end
            slots "warn(QString)"

            # Opens +filename+ and reads the data from there
            def open(filename, index_path: nil)
                history_widget.open(filename, index_path: index_path)
            end

            # Displays the data incoming from +client+
            #
            # +client+ is assumed to be a {DRoby::Logfile::Client} instance
            #
            # +update_period+ is, in seconds, the period at which the
            # display will check whether there is new data on the port.
            def connect(client, options = {})
                history_widget.connect(client, options)
            end

            # Creates a new display that will display the information
            # present in +filename+
            #
            # +plan_rebuilder+, if given, will be used to rebuild a complete
            # data structure based on the information in +filename+
            def self.from_file(filename, plan_rebuilder = nil)
                view = new(plan_rebuilder)
                view.open(filename)
                view
            end

            def load_options(path)
                if new_options = YAML.load(File.read(path))
                    apply_options(new_options)
                end
            end

            def save_options
                options = {}
                options["main"] = {}
                options["plugins"] = Roby.app.plugins.map(&:first)
                save_widget_state(options["main"], self)
                options["views"] = []
                displays.each do |klass_name, views|
                    views.each_with_index do |view, id|
                        next unless view

                        view_options = {}
                        view_options["class"] = view.class.name
                        view_options["id"] = id
                        save_widget_state(view_options, view)

                        if view.respond_to?(:save_options)
                            view_options.merge!(view.save_options)
                        end
                        options["views"] << view_options
                    end
                end
                options
            end

            def save_widget_state(options, widget)
                options["geometry"] =
                    [widget.geometry.x, widget.geometry.y,
                     widget.geometry.width, widget.geometry.height]
            end

            def apply_widget_state(options, widget)
                if geom = options["geometry"]
                    widget.set_geometry(*geom)
                end
            end

            def apply_options(options)
                (options["plugins"] || []).each do |plugin_name|
                    begin
                        Roby.app.using plugin_name
                    rescue ArgumentError => e
                        Roby.warn "the display configuration file mentions the "\
                                  "#{plugin_name} plugin, but it is not available "\
                                  "on this system. Some information might not "\
                                  "be displayed"
                    end
                end

                filters = options["plan_rebuilder"] || {}
                apply_widget_state(options["main"] || {}, self)
                (options["views"] || []).each do |view_options|
                    id = view_options["id"]
                    klass_name = view_options["class"]
                    if w = display_from_id(klass_name, id)
                        if w.class.name != klass_name
                            next
                        end
                    elsif !(w = create_display(klass_name, id))
                        next
                    end

                    apply_widget_state(view_options, w)
                    if w.respond_to?(:apply_options)
                        w.apply_options(view_options)
                    end
                end
            end
        end
    end
end
