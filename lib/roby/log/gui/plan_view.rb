module Roby
    module LogReplay
        class PlanView < Qt::Widget
            attr_reader :plan_rebuilder
            attr_reader :history_widget
            attr_reader :view

            # In remote connections, this is he period between checking if
            # there is data on the socket, in seconds
            #
            # See #connect
            def initialize(parent = nil, plan_rebuilder = nil)
                super(parent)
                plan_rebuilder ||= Roby::LogReplay::PlanRebuilder.new
                @plan_rebuilder = plan_rebuilder
                @history_widget = PlanRebuilderWidget.new(nil, plan_rebuilder)
            end

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
                if view.respond_to?(:options)
                    options = view.options(new_options)
                end
                if plan_rebuilder_options
                    options['plan_rebuilder'] = plan_rebuilder_options
                end
                options
            end

            def info(message)
                puts "INFO: #{message}"
            end

            def warn(message)
                puts "WARN: #{message}"
            end
        end
    end
end


