require 'Qt4'
require 'roby/app'
require 'roby/log/data_source'
require 'roby/log/gui/data_displays_ui'
require 'roby/log/gui/relations'
require 'roby/log/relations'

class DataSourceListModel < Qt::AbstractListModel
    attr_reader :sources
    def initialize(sources)
	@sources = sources
	super()
    end

    def rowCount(parent)
	if parent.valid? then 0
	else sources.size
	end
    end

    def flags(index)
	Qt::ItemIsSelectable | Qt::ItemIsEnabled
    end


    def data(index, role)
        return Qt::Variant.new unless role == Qt::DisplayRole && index.valid? && index.row < sources.size
        s = sources[index.row]
        return Qt::Variant.new(s.files.map { |f| File.basename(f) }.join(", ") + " [#{s.type}]")
    end

    def edit_at(index)
        return unless index.valid? && index.row < sources.size
	edit(sources[index.row])
	emit dataChanged(index, index)
    end

    def insertRow(row, parent)
        emit beginInsertRows(parent, row, row)
	if source = edit(nil)
	    @sources.insert row, source
	    return true
	end
    ensure
	emit endInsertRows()
    end

    def removeRow(row, parent)
        emit beginRemoveRows(parent, row, row)
        @sources.delete_at row
        emit endRemoveRows()
        true
    end

    def add_new(source = nil)
	if source
	    emit beginInsertRows(Qt::ModelIndex.new, sources.size, sources.size)
	    sources << source
	    emit endInsertRows()
	else
	    insertRow(sources.size, Qt::ModelIndex.new)
	end
    end
end


class FilteredDataSourceListModel < Qt::SortFilterProxyModel
    attr_reader :type, :sources
    attr_reader :source_combo
    attr_reader :display
    def initialize(source_combo, display, type, sources)
	super()
	@display = display
	@type    = type
	@sources = sources
	@source_combo = source_combo
    end
    def filterAcceptsRow(source_row, source_parent)
	if s = sources[source_row]
	    s.type == type
	else
	    false
	end
    end
    def selectedSource()
	index = source_combo.current_index
	index = self.index(index, 0, Qt::ModelIndex.new)
	
	sources[mapToSource(index).row].add_display(display)
    end
    slots 'selectedSource()'
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
    def add_display(sources, kind = nil)
	kind ||= display_types.current_text

	config_widget = Qt::Widget.new
	config_ui     = DISPLAYS[kind].new
	display	      = config_ui.setupUi(sources, config_widget)

	name = "#{kind}##{allocate_display_number}"
	idx  = display_configs.add_item(config_widget, name)
	display_configs.current_index = idx

	displays[config_ui] = display
	display.main.window_title = name
	display.main.show
	display
    end
end

if $0 == __FILE__
    a = Qt::Application.new(ARGV)
    w = Replay.new
    w.show
    a.exec
end

