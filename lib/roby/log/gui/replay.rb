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
	sources[source_row].type == type
    end
    def selectedSource()
	index = source_combo.current_index
	index = self.index(index, 0, Qt::ModelIndex.new)
	
	sources[mapToSource(index).row].add_display(display)
    end
    slots 'selectedSource()'
end

class Replay < Qt::MainWindow
    DISPLAYS = {
	'Relations' => Ui::RelationsConfig
    }
    attr_reader :displays
    attr_reader :sources
    attr_reader :sources_model

    attr_reader :ui

    KEY_GOTO = Qt::KeySequence.new('g')

    def initialize
	super()
	@play_speed = 1.0

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

	connect(ui.seek_start, SIGNAL("clicked()"), self, SLOT("seek_start()"))
	connect(ui.play, SIGNAL("toggled(bool)"), self, SLOT("play()"))
	connect(ui.play_step, SIGNAL("clicked()"), self, SLOT("play_step()"))
	connect(ui.faster, SIGNAL('clicked()')) do
	    factor = play_speed < 1 ? 10 : 1
	    self.play_speed = Float(Integer(factor * play_speed) + 1.0) / factor
	    if play_speed > 0.1
		ui.slower.enabled = true
	    end
	end
	connect(ui.slower, SIGNAL('clicked()')) do
	    factor = play_speed <= 1 ? 10 : 1
	    self.play_speed = Float(Integer(factor * play_speed) - 1.0) / factor
	    if play_speed == 0.1
		ui.slower.enabled = false
	    end
	end
	connect(ui.speed, SIGNAL('editingFinished()')) do
	    begin
		new_speed = Float(ui.speed.text)
		if new_speed <= 0
		    raise ArgumentError, "negative values are not allowed for speed"
		end
	    rescue ArgumentError
		Qt::MessageBox.warning self, "Invalid speed", "Invalid value for speed \"#{ui.speed.text}\": #{$!.message}"
		# Reinitialize the line edit to the old value
		self.play_speed = play_speed
	    end
	end
	connect(ui.goto, SIGNAL('clicked()'), self, SLOT('goto()'))

	@shortcuts = []
	@shortcuts << Qt::Shortcut.new(KEY_GOTO, self, SLOT('goto()'))
    end

    def play_speed=(value)
	ui.speed.text = value.to_s
	@play_speed = value

	if play_timer
	    play_timer.start(Integer(time_slice * 1000))
	end
    end
    def time_slice
	if play_speed < 1
	    BASE_TIME_SLICE / speed
	else
	    BASE_TIME_SLICE
	end
    end

    def displayed_sources
	sources.find_all { |s| !s.displays.empty? }
    end

    # Time of the first known sample
    attr_reader :first_sample
    # Time of the last known sample
    attr_reader :last_sample

    def seek_start; seek(nil) end
    slots 'seek_start()'

    def seek(time)
	displayed_sources.each { |s| s.prepare_seek(time) }
	if !time || time == Time.at(0)
	    min, max = displayed_sources.inject([nil, nil]) do |(min, max), source|
		source_min, source_max = source.range
		if !min || source_min < min
		    min = source_min
		end
		if !max || source_max > max
		    max = source_max
		end
		[min, max]
	    end
		    
	    @first_sample = @time = min
	    @last_sample  = max
	    ui.progress.minimum = first_sample.to_i
	    ui.progress.maximum = last_sample.to_i
	else
	    play_until time
	end

	ui.time_lcd.display(self.time - first_sample)
	ui.progress.value = self.time.to_i
    end

    def goto
	user_time = begin
			user_time = Qt::InputDialog.get_text nil, 'Going to ...', 
					"<html><b>Go to time</b><ul><li>use \'+\' for a relative jump forward</li><li>'-' for a relative jump backwards</li></ul></html>", 
					Qt::LineEdit::Normal, (user_time || @last_goto || "")
			return if !user_time || user_time.empty?
			@last_goto = user_time
			if user_time =~ /^\s*([\+\-])(.*)/
			    op = $1
			    user_time = $2
			end
			user_time = Time.from_hms(user_time) - Time.at(0)

		    rescue ArgumentError
			Qt::MessageBox.warning self, "Invalid user_time", "Invalid user_time: #{$!.message}"
			retry
		    end

	seek_start unless first_sample
	user_time = if op
			self.time.send(op, user_time)
		    else
			first_sample + user_time
		    end
	seek(user_time)
    end
    slots 'goto()'

    def allocate_display_number; @display_number += 1 end
    attr_reader :time

    def next_step_time
	displayed_sources.
	    map { |s| s.next_step_time }.
	    compact.min 
    end

    BASE_TIME_SLICE = 0.5
    attr_reader :play_timer, :play_speed
    def play
	if ui.play.checked?
	    seek_start unless first_sample

	    @play_timer = Qt::Timer.new(self)
	    connect(play_timer, SIGNAL("timeout()"), self, SLOT("play_step_timer()"))
	    play_timer.start(Integer(time_slice * 1000))
	else
	    play_timer.stop
	end
    end
    slots 'play()'

    def stop
	ui.play.checked = false
	play_timer.stop if play_timer
	@play_timer = nil
    end
    slots 'stop()'

    def play_step
	seek_start unless first_sample
       	play_until(next_step_time) 
    end
    slots 'play_step()'

    def play_step_timer
	start = Time.now
	play_until(time + time_slice * play_speed)

	STDERR.puts time.to_hms
	STDERR.puts "play: #{Time.now - start}"
    end
    slots 'play_step_timer()'
    
    def play_until(max_time)
	displayed_sources.inject(timeline = []) do |timeline, s| 
	    if s.next_step_time
		timeline << [s.next_step_time, s]
	    end
	    timeline
	end

	if timeline.empty?
	    stop
	    return
	end

	updated_sources = Set.new

	timeline.sort_by { |t, _| t }
	while !timeline.empty? && timeline[0][0] <= max_time
	    timeline.sort_by { |t, _| t }
	    @time, source = timeline.first

	    source.advance
	    updated_sources << source
	    if next_time = source.next_step_time
		timeline[0] = [next_time, source]
	    else
		timeline.shift
	    end
	end

	updated_sources.each do |source|
	    source.displays.each do |d| 
		d.update
	    end
	end

	if timeline.empty? then stop
	else @time = max_time
	end

	if time > last_sample
	    last_sample = time
	    if ui.progress.maximum < time.to_i
		ui.progress.maximum = (first_sample + (last_sample - first_sample) * 4 / 3).to_i
	    end
	end
	ui.progress.value = time.to_i
	ui.time_lcd.display(time - first_sample)
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

	config_widget = Qt::Widget.new
	config_ui = DISPLAYS[kind].new
	display = config_ui.setupUi(self, config_widget)


	name = "#{kind}##{allocate_display_number}"
	idx  = ui.displays.add_item(config_widget, name)
	ui.displays.current_index = idx

	displays[config_ui] = display
	display.main.window_title = "#{window_title}: #{name}"
	display.main.show
	shortcut = Qt::Shortcut.new(KEY_GOTO, display.main)
	connect(shortcut, SIGNAL('activated()'), self, SLOT('goto()'))
	@shortcuts << shortcut
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

