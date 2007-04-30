require 'Qt4'
require 'roby/app'

require 'roby/log/gui/replay_controls_ui'
require 'roby/log/gui/data_displays'

class RemoteSourceListModel < DataSourceListModel
    def edit(source)
	address = Qt::InputDialog.get_text(nil, 
	    "New data source",
	    "Address of the data source server")

	if !address || address.empty?
	    return
	end

	begin
	    DRb.start_service
	    socket = TCPSocket.new(address)
	rescue Exception
	    Qt::MessageBox.new("

	dir = if !source || source.files.empty? then ""
	      else File.dirname(source.files.first) end

	newfiles = Qt::FileDialog.get_open_file_names nil, "New data source", dir
	return if newfiles.empty?
	if !newfiles.empty?
	    if newsource = Roby.app.data_source(newfiles)
		return newsource
	    else
		Qt::MessageBox.warning self, "Add data source", "Cannot determine data source type for #{newfiles.join(", ")}"
		return
	    end
	end
    end
end

class RuntimeDisplay < Qt::MainWindow
    attr_reader :sources
    attr_reader :sources_model

    def initialize
	super()

	# Create the vertical layout for this window
	central_widget = Qt::Widget.new(self)
	layout = Qt::VBoxLayout.new(central_widget)
	layout.spacing = 6
	layout.margin  = 0

	# add support for the data sources and display setup
	@sources = Array.new
	@sources_model = DataSourceListModel.new(sources)
	displays_holder = Qt::Widget.new(central_widget)
	layout.add_widget displays_holder
	@ui_displays = Ui_DataDisplays.new
	ui_displays.setupUi(displays_holder)
	ui_displays.sources.model = sources_model
	connect(ui_displays.add_source, SIGNAL("clicked()"), self, SLOT("add_source()"))
	connect(ui_displays.remove_source, SIGNAL("clicked()"), self, SLOT("remove_source()"))
	connect(ui_displays.display_add, SIGNAL("clicked()"), self, SLOT("add_display()"))
end
