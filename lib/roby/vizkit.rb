require 'Qt'
require 'roby/log/event_stream'
require 'roby/log/plan_rebuilder'
require 'roby/log/server'
require 'roby/log/relations_view/relations_view'
require 'vizkit'

begin
    DRb.current_server
rescue DRb::DRbServerNotFound
    DRb.start_service
end

Vizkit::UiLoader.register_ruby_widget('RobyPlanDisplay', Roby::LogReplay::RelationsDisplay::RelationsView.method(:new))
