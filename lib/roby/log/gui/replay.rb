require 'Qt4'
require 'roby/log/data_source'
require 'roby/log/gui/replay_ui'
require 'roby/log/gui/relations'

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

    def add_new(source = nil)
	if source
	    emit beginInsertRows(Qt::ModelIndex.new, sources.size, sources.size)
	    sources << source
	    emit endInsertRows()
	else
	    insertRow(sources.size, Qt::ModelIndex.new)
	end
    end

    def edit_at(index)
        return unless index.valid? && index.row < sources.size
	edit(sources[index.row])
	emit dataChanged(index, index)
    end

    def edit(source)
	dir = if source.files.empty? then ""
	      else File.dirname(source.files.first) end

	newfiles = Qt::FileDialog.get_open_file_names nil, "New data source", dir
	return if newfiles.empty?
	if !newfiles.empty?
	    if newsource = Roby.app.data_source(newfiles)
		return newsource
	    else
		Qt::MessageBox.warning nil, "Add data source", "Cannot determine data source type for #{newfiles.join(", ")}"
		return
	    end
	end
    end

    def insertRow(row, parent)
        emit beginInsertRows(parent, row, row)
	if source = edit(Roby::Log::DataSource.new)
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
end

class FilteredDataSourceListModel < Qt::SortFilterProxyModel
    attr_reader :type, :sources
    def initialize(type, sources)
	super()
	@type    = type
	@sources = sources
    end
    def filterAcceptsRow(source_row, source_parent)
	sources[source_row].type == type
    end
end

class Replay < Qt::MainWindow
    DISPLAYS = {
	'Relations' => Ui::RelationsConfig
    }
    attr_reader :displays
    attr_reader :sources
    attr_reader :sources_model

    attr_reader :ui
    def initialize
	super()
	@ui = Ui_Replay.new
	ui.setupUi(self)

	@displays = Hash.new
	@display_number = 0
	connect(ui.display_add, SIGNAL("clicked()"), self, SLOT("add_display()"))

	@sources = Array.new
	@sources_model = DataSourceListModel.new(sources)
	ui.sources.model = @sources_model
	connect(ui.add_source, SIGNAL("clicked()"), self, SLOT("add_source()"))
	connect(ui.remove_source, SIGNAL("clicked()"), self, SLOT("remove_source()"))
    end

    def allocate_display_number
	@display_number += 1
    end

    def time
	displays.map { |d| d.next_time }.min
    end

    BASE_STEP = 0.5
    def play(speed = 1.0)
	@play_speed = 1.0
	@play_timer = Qt::Timer.new(self)
	connect(play_timer, SIGNAL("timeout()"), self, SLOT("play_step()"))
	play_timer.start(Integer(BASE_STEP * 1000))
    end

    def play_step
	play_until(time + BASE_STEP * play_speed)
	unless time
	    play_timer.stop
	end
    end
    slots 'play_step()'

    def play_until(max_time)
	displays.inject(timeline = []) { |timeline, d| timeline << [d.next_time, d] }
	while timeline.first < max
	    timeline.sort_by { |t, _| t }
	    _, display = timeline.first

	    if display.advance
		timeline[0] = [display.next_time, display]
	    else
		timeline.shift
	    end
	end
    end

    def rewind
	@position = 0
	displays.each_value { |d| d.clear }
    end

    def add_source(source = nil)
	sources_model.add_new(source)
    end
    slots 'add_source()'

    def remove_source
	index = ui.sources.current_index.row
	sources_model.removeRow(index, Qt::ModelIndex.new)
    end
    slots 'remove_source()'

    def add_display(kind = nil)
	kind ||= ui.display_types.current_text

	w  = Qt::Widget.new
	w_ui = DISPLAYS[kind].new
	display = w_ui.setupUi(self, w)

	name = "#{kind}##{allocate_display_number}"
	idx  = ui.displays.add_item(w, name)
	ui.displays.current_index = idx

	displays[w_ui] = display
	Roby::Log.loggers << display
	display.view.window_title = "#{window_title}: #{name}"
	display.view.show
	display
    end
    slots 'add_display()'
end

if $0 == __FILE__
    a = Qt::Application.new(ARGV)
    w = Replay.new
    w.show
    a.exec
end

