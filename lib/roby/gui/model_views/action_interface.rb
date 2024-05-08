# frozen_string_literal: true

module Roby
    module GUI
        module ModelViews
            # Handler class to display information about an action interface
            class ActionInterface < MetaRuby::GUI::HTML::Collection
                def compute_toplevel_links(model, options)
                    model.each_action.map do |action|
                        arguments = action.arguments.map { |arg| ":#{arg.name}" }.join(", ")
                        format = "#{action.name}(#{arguments}) => #{page.link_to(action.returned_type)}: #{action.doc}"
                        Element.new(action.name, format, element_link_target(action, options[:interactive]), action.name, {})
                    end
                end

                def render(model, options = {})
                    ActionInterface.html_defined_in(page, model, with_require: true)

                    actions = compute_toplevel_links(model, options)
                    render_links("Actions", actions)
                end

                def self.find_definition_place(model)
                    location = model.definition_location.find do |location|
                        break if location.label == "require" ||
                                 location.label == "using_task_library"

                        Roby.app.app_file?(location.absolute_path)
                    end

                    [location.absolute_path, location.lineno] if location
                end

                def self.html_defined_in(page, model, with_require: true, definition_location: nil, format: "<b>Defined in</b> %s")
                    path, lineno = *definition_location || find_definition_place(model)
                    return unless path

                    path = Pathname.new(path)
                    path_link = page.link_to(path, "#{path}:#{lineno}", lineno: lineno)
                    page.push(nil, "<p>#{format(format, path_link)}</p>")
                    return unless with_require

                    req_base = $LOAD_PATH.find { |p| path.fnmatch?(File.join(p, "*")) }
                    return unless req_base

                    req = path.relative_path_from(Pathname.new(req_base))
                    page.push(nil, "<code>require '#{req.sub_ext('')}'</code>")
                end
            end
        end
    end
end
