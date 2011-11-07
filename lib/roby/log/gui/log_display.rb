module Roby
    module LogReplay
        # Main UI for log display
        #
        # It includes
        class LogDisplay < Qt::Widget
            # The PlanRebuilder object that gets the data
            attr_reader :plan_rebuilder
            # The history widget
            attr_reader :history_widget
            # The set of displays that have been created so far
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
                { 'Relations' => 'Roby::LogReplay::RelationsView',
                  'Chronicle' => 'Roby::LogReplay::ChronicleView' }

            def initialize(parent = nil, plan_rebuilder = nil)
                super

                plan_rebuilder ||= Roby::LogReplay::PlanRebuilder.new
                @plan_rebuilder = plan_rebuilder

                @displays = []

                @btn_create_display = Qt::PushButton.new("New Display", self)
                @lbl_info = Qt::Label.new(self)
                @history_widget = PlanRebuilderWidget.new(self, plan_rebuilder)
                @layout = Qt::VBoxLayout.new(self)
                @layout.add_widget(@btn_create_display)
                @layout.add_widget(@lbl_info)
                @layout.add_widget(@history_widget)

                Qt::Object.connect(history_widget, SIGNAL('sourceChanged()'),
                                   self, SLOT('updateWindowTitle()'))

                btn_create_display.text = "New Display"
                @menu_displays = Qt::Menu.new(@btn_create_display)
                self.class.available_displays.each do |name, klass_name|
                    action = menu_displays.addAction(name)
                    action.setData(Qt::Variant.new(klass_name))
                end
                btn_create_display.setMenu(menu_displays)
                menu_displays.connect(SIGNAL('triggered(QAction*)')) do |action|
                    create_display(action.data.toString)
                end

                resize(300, 500)
            end

            def updateWindowTitle
                self.window_title = history_widget.window_title
            end
            slots 'updateWindowTitle()'

            def create_all_displays
                self.class.available_displays.each do |user_name, klass_name|
                    create_display(klass_name)
                end
            end

            def create_display(name)
                # Check whether +klass_name+ is not a user-visible string
                self.class.available_displays.each do |user_name, klass_name|
                    if user_name.downcase == name.downcase
                        name = klass_name
                        break
                    end
                end

                klass = eval(name)
                view = klass.new(@history_widget)

                Qt::Object.connect(history_widget, SIGNAL('update(QDateTime)'),
                                   view, SLOT('update(QDateTime)'))
                Qt::Object.connect(history_widget, SIGNAL('sourceChanged()'),
                                   view, SLOT('updateWindowTitle()'))
                view.show
                @displays << view
            end

            def info(message)
                lbl_info.text = message
            end
            slots 'info(QString)'

            def warn(message)
                lbl_info.setText("<font color=\"red\">#{message}</font>")
            end
            slots 'warn(QString)'

            # Opens +filename+ and reads the data from there
            def open(filename)
                history_widget.open(filename)
            end

            # Displays the data incoming from +client+
            #
            # +client+ is assumed to be a Roby::Log::Client instance
            #
            # +update_period+ is, in seconds, the period at which the
            # display will check whether there is new data on the port.
            def connect(client, options = Hash.new)
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
                    options(new_options)
                end
            end

            def options(new_options = Hash.new)
                filters = new_options.delete('plan_rebuilder') || Hash.new
                plan_rebuilder_options = plan_rebuilder.options(filters)

                options = Hash.new
                displays.each do |view|
                    if view.respond_to?(:options)
                        options = view.options(new_options)
                    end
                end
                if plan_rebuilder_options
                    options['plan_rebuilder'] = plan_rebuilder_options
                end
                options
            end
        end
    end
end

