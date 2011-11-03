module Roby
    module LogReplay
        # Widget that can be used to display the information about a plan object
        # (either relation or task)
        #
        # The object should be provided to #display to update the view.
        # #activate can then be used to show the widget and make it toplevel
        # (force its visibility).
        class ObjectInfoView < Qt::ListWidget
            def initialize(parent = nil)
                super
                resize(400, 400)

                connect(SIGNAL('itemDoubleClicked(QListWidgetItem*)')) do |item|
                    emit selectedTime(item.data(Qt::UserRole).to_float)
                end
            end

            # Updates the view to display the information about +obj+
            def display(obj)
                sections = []
                if obj.kind_of?(Array)
                    from, to, rel = obj
                    section = [
                        "#{rel}",
                        [ "from: #{from}",
                          "to: #{to}",
                          "info: #{from[to, rel]}"]
                    ]
                    sections << section

                elsif obj.kind_of?(Roby::LogReplay::RelationsDisplay::DisplayTask)
                    sections << ["Model", obj.class.name]
                    # Add general task information (owner, arguments, ...)
                    text = obj.arguments.map do |key, value|
                        "#{key}: #{value}"
                    end
                    sections << ["Arguments", text]

                    # Add the history
                    if obj.failed_to_start?
                        text = []
                        text << ["Failed to start at #{Roby.format_time(obj.failed_to_start_time)}", obj.failed_to_start_time]
                        text.concat(Roby.format_exception(obj))
                    else
                        text = obj.history.map do |event| 
                            time = event.time
                            time_as_text = "#{Roby.format_time(event.time)}"
                            ["#{time_as_text}: #{event.symbol}", time]
                        end
                    end
                    sections << ["History", text]
                    sections << ["Model Ancestry", obj.class.ancestors.map(&:name)]
                else return false
                end

                self.windowTitle = "Details for #{obj}"
                clear
                sections.each do |header, lines|
                    if header
                        item = Qt::ListWidgetItem.new(self)
                        item.text = header
                        item.background = Qt::Brush.new(Qt::Color.new("#45C1FF"))
                        font = item.font
                        font.weight = Qt::Font::Bold
                        item.font = font
                    end
                    lines.each do |txt, time|
                        item = Qt::ListWidgetItem.new("  #{txt}")
                        if time
                            puts "#{txt} #{time} #{time.to_f}"
                            item.setData(Qt::UserRole, Qt::Variant.new(time.to_f))
                        end
                        addItem(item)
                    end
                end
            end

            signals 'selectedTime(float)'

            # Shows the widget and makes it visible (i.e. toplevel)
            def activate
                show
                activateWindow
            end
        end
    end
end

