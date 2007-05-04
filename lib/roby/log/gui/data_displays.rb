require 'Qt4'
require 'roby/app'
require 'roby/log/data_stream'
require 'roby/log/gui/data_displays_ui'
require 'roby/log/gui/relations'
require 'roby/log/relations'

class DataStreamListModel < Qt::AbstractListModel
    attr_reader :streams
    def initialize(streams)
	@streams = streams
	super()
    end

    def rowCount(parent)
	if parent.valid? then 0
	else streams.size
	end
    end

    def flags(index)
	Qt::ItemIsSelectable | Qt::ItemIsEnabled
    end

    def data(index, role)
        return Qt::Variant.new unless role == Qt::DisplayRole && index.valid? && index.row < streams.size
        s = streams[index.row]
        return Qt::Variant.new(s.name + " [#{s.type}]")
    end

    def edit_at(index)
        return unless index.valid? && index.row < streams.size
	edit(streams[index.row])
	emit dataChanged(index, index)
    end

    def insertRow(row, parent)
        emit beginInsertRows(parent, row, row)
	if stream = edit(nil)
	    @streams.insert row, stream
	    return true
	end
    ensure
	emit endInsertRows()
    end

    def removeRow(row, parent)
        emit beginRemoveRows(parent, row, row)
        @streams.delete_at row
        emit endRemoveRows()
        true
    end

    def add_new(stream = nil)
	if stream
	    emit beginInsertRows(Qt::ModelIndex.new, streams.size, streams.size)
	    streams << stream
	    emit endInsertRows()
	else
	    insertRow(streams.size, Qt::ModelIndex.new)
	end
    end
end


class FilteredDataStreamListModel < Qt::SortFilterProxyModel
    attr_reader :type, :streams
    attr_reader :stream_combo
    attr_reader :display
    def initialize(stream_combo, display, type, streams)
	super()
	@display = display
	@type    = type
	@streams = streams
	@stream_combo = stream_combo
    end
    def filterAcceptsRow(stream_row, stream_parent)
	if s = streams[stream_row]
	    s.type == type
	else
	    false
	end
    end
    def selectedStream()
	index = stream_combo.current_index
	index = self.index(index, 0, Qt::ModelIndex.new)
	display.stream = streams[mapToSource(index).row]
    end
    slots 'selectedStream()'
end

class DisplayConfigHandler < Qt::Widget
    attr_reader :display_configs
    attr_reader :config_ui
    attr_reader :display

    def setup(data_displays, config_ui)
	@display_configs = data_displays.display_configs
	@display = data_displays.displays[config_ui]
	@config_ui = config_ui

	connect(config_ui.close, SIGNAL('clicked()'), self, SLOT('close()'))
    end

    def close
	idx = display_configs.index_of(self)
	if display.decoder
	    display.decoder.displays.delete(display)
	end
	display.main.close
	display_configs.remove_item idx
    end
    slots 'close()'
end

class Ui_DataDisplays
    DISPLAYS = {
	'Relations' => Ui::RelationsConfig
    }
    attr_reader :displays

    def initialize
	super()

	@displays	= Hash.new
	@display_number = 0
    end

    def allocate_display_number; @display_number += 1 end
    def add_display(streams, kind = nil)
	kind ||= display_types.current_text

	config_widget = DisplayConfigHandler.new
	config_ui     = DISPLAYS[kind].new
	display	      = config_ui.setupUi(streams, config_widget)

	name = "#{kind}##{allocate_display_number}"
	idx  = display_configs.add_item(config_widget, name)
	display_configs.current_index = idx

	displays[config_ui] = display
	display.main.window_title = name
	display.main.show
	display.config_ui = config_ui

	main_window = display.main
	main_window.singleton_class.class_eval do
	    define_method(:closeEvent) do |event|
		config_ui.close.clicked
	    end
	end
	config_widget.setup(self, config_ui)

	display
    end
end

if $0 == __FILE__
    a = Qt::Application.new(ARGV)
    w = Replay.new
    w.show
    a.exec
end

