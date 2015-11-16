require 'roby/log/gui/relations_view/relations_canvas'
module Roby
    module GUI
        module ModelViews
            # Handler class to display information about a task model
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

                TEMPLATE_PATH = File.expand_path('task.rhtml', File.dirname(__FILE__))
                TEMPLATE = ERB.new(File.read(TEMPLATE_PATH))
                TEMPLATE.filename = TEMPLATE_PATH

                def render(task_model, options = Hash.new)
                    html = TEMPLATE.result(binding)
                    svg  = Roby::LogReplay::RelationsDisplay::DisplayTask.to_svg(task_model.new)

                    options, push_options = Kernel.filter_options options,
                        external_objects: false, doc: true
                    if external_objects = options[:external_objects]
                        file = external_objects % 'roby_task' + ".svg"
                        File.open(file, 'w') { |io| io.write(svg) }
                        svg = "<object data=\"#{file}\" type=\"image/svg+xml\"></object>"
                    end

                    if options[:doc] && task_model.doc
                        page.push nil, page.main_doc(task_model.doc)
                    end
                    page.push('Roby Task Model', TEMPLATE.result(binding), push_options)
                end

                signals 'updated()'
            end
        end
    end
end
