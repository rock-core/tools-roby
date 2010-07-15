require 'roby/log/event_stream'
require 'roby/log/relations'
require 'roby/log/gui/relations'

Roby::LogReplay::EventStream.register_display('roby-events', Roby::LogReplay::RelationsDisplay::RelationsCanvas)
LogTools.available_stream_classes << Roby::LogReplay::EventStream

