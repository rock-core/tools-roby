require 'roby/log/gui/relations_view/relations_canvas'
module Roby
    module GUI
        module ModelViews
            # Handler class to display information about a task model
            #
            # It is compatible
            class Task < Qt::Object
                attr_reader :page

                def initialize(page)
                    @page = page
                    super()
                end
                def enable
                end
                def disable
                end
                def clear
                end

                TEMPLATE_PATH = File.expand_path('task.html', File.dirname(__FILE__))
                TEMPLATE = ERB.new(File.read(TEMPLATE_PATH))
                def render(task_model)
                    html = TEMPLATE.result(binding)
                    svg  = Roby::LogReplay::RelationsDisplay::DisplayTask.to_svg(task_model.new)
                    page.push('Roby Task Model', TEMPLATE.result(binding))
                end
            end
        end
    end
end
