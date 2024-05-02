# frozen_string_literal: true

require "webgen/tag"

# Handler for rdoc_links tag in the documentation
class RdocLinks
    include Webgen::Tag::Base

    def call(_tag, _body, context)
        name = param("rdoclinks.name")
        if (base_module = param("rdoclinks.base_module"))
            name = "#{base_module}::#{name}"
        end

        class_name =
            if (m = /(?:\.|#)(\w+)$/.match(name))
                m.pre_match
            else
                name
            end

        path = "#{class_name.split('::').join('/')}.html"
        url = "#{param('rdoclinks.base_url')}/#{path}"

        "<a href=\"#{context.ref_node.route_to(url)}\">" \
            "#{param('rdoclinks.text') || param('rdoclinks.name')}</a>"
    end
end

config = Webgen::WebsiteAccess.website.config
config.rdoclinks.name        "", mandatory: "default"
config.rdoclinks.base_webgen "", mandatory: false
config.rdoclinks.base_url    "", mandatory: false
config.rdoclinks.base_module nil, mandatory: false
config.rdoclinks.full_name   false, mandatory: false
config.rdoclinks.text nil, mandatory: false
config["contentprocessor.tags.map"]["rdoc_class"] = "RdocLinks"
