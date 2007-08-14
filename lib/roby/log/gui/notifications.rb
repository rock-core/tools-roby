require 'roby/log/gui/basic_display_ui'
require 'roby/log/notifications'

module Ui
    class NotificationsConfig < Ui::BasicDisplayConfig
	attr_reader :streams_model

	def setupUi(streams_model, widget)
	    super(widget)

	    display = NotificationsDisplay.new
	    @streams_model = FilteredDataStreamListModel.new(stream, display, 'roby-events', streams_model.streams)
	    Qt::Object.connect(stream, SIGNAL("currentIndexChanged(int)"), @streams_model, SLOT("selectedStream()"))
	    @streams_model.source_model = streams_model
	    stream.model		= @streams_model
	    display
	end

	def self.setup_optparse(opt, replay)
	    opt.on("--notifications") do
		replay.add_display('Notifications')
	    end
	end
    end
end

