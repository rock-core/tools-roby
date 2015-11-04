module Roby
    module GUI
        module ModelViews
            # Handler class to display information about an action interface
            class ActionInterface < MetaRuby::GUI::HTML::Collection
                def initialize(page)
                    super
                end

                def compute_toplevel_links(model, options)
                    actions = model.each_action.map do |action|
                        arguments = action.arguments.map { |arg| ":#{arg.name}" }.join(", ")
                        format = "#{action.name}(#{arguments}) => #{page.link_to(action.returned_type)}: #{action.doc}"
                        Element.new(action.name, format, element_link_target(action, options[:interactive]), action.name, Hash.new)
                    end
                end

                def render(model, options = Hash.new)
                    ActionInterface.html_defined_in(page, model, with_require: true)

                    actions = compute_toplevel_links(model, options)
                    render_links('Actions', actions)
                end

                def self.find_definition_place(model)
                    model.definition_location.find do |file, _, method|
                        return if method == :require || method == :using_task_library
                        Roby.app.app_file?(file)
                    end
                end

                def self.html_defined_in(page, model, with_require: true, definition_location: nil, format: "<b>Defined in</b> %s")
                    path, lineno = *definition_location || find_definition_place(model)
                    if path
                        path = Pathname.new(path)
                        path_link = page.link_to(path, "#{path}:#{lineno}", lineno: lineno)
                        page.push(nil, "<p>#{format % [path_link]}</p>")
                        if with_require
                            if req_base = $LOAD_PATH.find { |p| path.fnmatch?(File.join(p, "*")) }
                                req = path.relative_path_from(Pathname.new(req_base))
                                page.push(nil, "<code>require '#{req.sub_ext("")}'</code>")
                            end
                        end
                    end
                end
            end
        end
    end
end

