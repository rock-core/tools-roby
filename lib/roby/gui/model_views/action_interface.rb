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
                        format = "#{action.name}(#{arguments}) => #{action.returned_type.name}: #{action.doc}"
                        Element.new(action.name, format, element_link_target(action, options[:interactive]), action.name, Hash.new)
                    end
                end

                def render(model, options = Hash.new)
                    actions = compute_toplevel_links(model, options)
                    render_links('Actions', actions)
                end
            end
        end
    end
end

