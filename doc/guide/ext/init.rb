# frozen_string_literal: true

# = webgen extensions directory
#
# All init.rb files anywhere under this directory get automatically loaded on a
# webgen run. This allows you to add your own extensions to webgen or to modify
# webgen's core!
#
# If you don't need this feature you can savely delete this file and the
# directory in which it is!
#
# The +config+ variable below can be used to access the Webgen::Configuration
# object for the current website.
config = Webgen::WebsiteAccess.website.config
config["sourcehandler.patterns"]["Webgen::SourceHandler::Copy"] << "**/autoproj_bootstrap"
config["sourcehandler.patterns"]["Webgen::SourceHandler::Copy"] << "**/manifest.xml"
config["sourcehandler.patterns"]["Webgen::SourceHandler::Copy"] << "**/*.svg"
config["sourcehandler.patterns"]["Webgen::SourceHandler::Copy"] << "**/*.pdf"
config["sourcehandler.patterns"]["Webgen::SourceHandler::Copy"] << "**/*.rb"

$LOAD_PATH.unshift File.expand_path("..", File.dirname(__FILE__))
require "ext/rdoc_links"
require "ext/previous_next"
require "ext/extended_menu"
