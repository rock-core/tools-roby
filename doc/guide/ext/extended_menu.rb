# frozen_string_literal: true

module Webgen::Tag
    class Menu
        alias __specific_menu_tree_for__ specific_menu_tree_for

        def specific_menu_tree_for(content_node)
            tree = __specific_menu_tree_for__(content_node)
            return unless tree

            tree.children.delete_if do |menu_info|
                si = menu_info.node["sort_info"]
                next unless si

                if param("tag.menu.range_start") && si < param("tag.menu.range_start")
                    true
                else
                    param("tag.menu.range_end") && si > param("tag.menu.range_end")
                end
            end
            tree
        end
    end
end

config = Webgen::WebsiteAccess.website.config
config.tag.menu.range_start nil, mandatory: false
config.tag.menu.range_end   nil, mandatory: false
