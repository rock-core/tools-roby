require 'Qt'
require 'roby/log/event_stream'
require 'roby/log/plan_rebuilder'
require 'roby/log/relations_view/relations_view'
require 'vizkit'

Vizkit::UiLoader.register_ruby_widget('RobyRelations', Roby::Log::RelationsDisplay::RelationsView.method(:new))
