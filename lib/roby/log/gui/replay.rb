require 'Qt4'
require 'roby/app'

require 'roby/log/gui/replay_controls_ui'
require 'roby/log/gui/data_displays'

# This class is a data source list model for offline replay:
# it holds a list of log file which can then be used for
# display by log/replay
class OfflineSourceListModel < DataSourceListModel
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
end

class Replay < Qt::MainWindow
    attr_reader :displays
    attr_reader :sources
    attr_reader :sources_model

    # The widget which controls the data source => display mapping, and display
    # control
    attr_reader :ui_displays
    # The widget which hold the replay controls (play, pause, ...)
    attr_reader :ui_controls

    KEY_GOTO = Qt::KeySequence.new('g')

    def initialize
	super()
	@play_speed = 1.0

	# Create the vertical layout for this window
	central_widget = Qt::Widget.new(self)
	layout = Qt::VBoxLayout.new(central_widget)
	layout.spacing = 6
	layout.margin  = 0

	# add support for the data sources and display setup
	@sources = Array.new
	@sources_model = OfflineSourceListModel.new(sources)
	displays_holder = Qt::Widget.new(central_widget)
	layout.add_widget displays_holder
	@ui_displays = Ui_DataDisplays.new
	ui_displays.setupUi(displays_holder)
	ui_displays.sources.model = sources_model
	connect(ui_displays.add_source, SIGNAL("clicked()"), self, SLOT("add_source()"))
	connect(ui_displays.remove_source, SIGNAL("clicked()"), self, SLOT("remove_source()"))
	connect(ui_displays.display_add, SIGNAL("clicked()"), self, SLOT("add_display()"))

	controls_holder = Qt::Widget.new(central_widget)
	layout.add_widget controls_holder
	@ui_controls = Ui_ReplayControls.new
	ui_controls.setupUi(controls_holder)
	connect(ui_controls.seek_start, SIGNAL("clicked()"), self, SLOT("seek_start()"))
	connect(ui_controls.play, SIGNAL("toggled(bool)"), self, SLOT("play()"))
	connect(ui_controls.play_step, SIGNAL("clicked()"), self, SLOT("play_step()"))
	connect(ui_controls.faster, SIGNAL('clicked()')) do
	    factor = play_speed < 1 ? 10 : 1
	    self.play_speed = Float(Integer(factor * play_speed) + 1.0) / factor
	    if play_speed > 0.1
		ui_controls.slower.enabled = true
	    end
	end
	connect(ui_controls.slower, SIGNAL('clicked()')) do
	    factor = play_speed <= 1 ? 10 : 1
	    self.play_speed = Float(Integer(factor * play_speed) - 1.0) / factor
	    if play_speed == 0.1
		ui_controls.slower.enabled = false
	    end
	end
	connect(ui_controls.speed, SIGNAL('editingFinished()')) do
	    begin
		new_speed = Float(ui_controls.speed.text)
		if new_speed <= 0
		    raise ArgumentError, "negative values are not allowed for speed"
		end
	    rescue ArgumentError
		Qt::MessageBox.warning self, "Invalid speed", "Invalid value for speed \"#{ui_controls.speed.text}\": #{$!.message}"
		# Reinitialize the line edit to the old value
		self.play_speed = play_speed
	    end
	end
	connect(ui_controls.goto, SIGNAL('clicked()'), self, SLOT('goto()'))


	self.central_widget = central_widget

	@shortcuts = []
	@shortcuts << Qt::Shortcut.new(KEY_GOTO, self, SLOT('goto()'))
    end

    def play_speed=(value)
	ui_controls.speed.text = value.to_s
	@play_speed = value

	if play_timer
	    play_timer.stop
	    play_timer.start(Integer(time_slice * 1000))
	end
    end
    def time_slice
	if play_speed < 1
	    BASE_TIME_SLICE / play_speed
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
	if time && !first_sample
	    seek_start 
	elsif time && first_sample && time < first_sample
	    time = nil
	end

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
	    ui_controls.progress.minimum = first_sample.to_i
	    ui_controls.progress.maximum = last_sample.to_i
	else
	    play_until time
	end

	ui_controls.time_lcd.display(self.time - first_sample)
	ui_controls.progress.value = self.time.to_i
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

    attr_reader :time

    def next_step_time
	displayed_sources.
	    map { |s| s.next_step_time }.
	    compact.min 
    end

    BASE_TIME_SLICE = 0.5
    attr_reader :play_timer, :play_speed
    def play
	if ui_controls.play.checked?
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
	ui_controls.play.checked = false
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
	    source.update_display
	end

	if timeline.empty? then stop
	else @time = max_time
	end

	if time > last_sample
	    last_sample = time
	    if ui_controls.progress.maximum < time.to_i
		ui_controls.progress.maximum = (first_sample + (last_sample - first_sample) * 4 / 3).to_i
	    end
	end
	ui_controls.progress.value = time.to_i
	ui_controls.time_lcd.display(time - first_sample)

    rescue Exception => e
	message = "<html>#{Qt.escape(e.message)}<ul><li>#{e.backtrace.join("</li><li>")}</li></ul></html>"
	Qt::MessageBox.critical self, "Replay failure", message
	stop
    end

    def add_source(source = nil)
	sources_model.add_new(source)
    end
    slots 'add_source()'

    def remove_source
	index = ui_displays.sources.current_index.row
	sources_model.removeRow(index, Qt::ModelIndex.new)
    end
    slots 'remove_source()'

    def add_display(kind = nil)
	display  = ui_displays.add_display(sources_model, kind)
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

