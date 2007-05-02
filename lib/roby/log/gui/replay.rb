require 'Qt4'
require 'roby/app'
require 'optparse'

require 'roby/log/gui/replay_controls_ui'
require 'roby/log/gui/data_displays'

# This class is a data stream list model for offline replay:
# it holds a list of log file which can then be used for
# display by log/replay
class OfflineStreamListModel < DataStreamListModel
    def edit(stream)
	dir = if !stream || stream.files.empty? then ""
	      else File.dirname(stream.files.first) end

	newfiles = Qt::FileDialog.get_open_file_names nil, "New data stream", dir
	return if newfiles.empty?
	if !newfiles.empty?
	    if newstream = Roby.app.data_stream(newfiles)
		return newstream
	    else
		Qt::MessageBox.warning self, "Add data stream", "Cannot determine data stream type for #{newfiles.join(", ")}"
		return
	    end
	end
    end
end

class Replay < Qt::MainWindow
    attr_reader :displays
    attr_reader :streams
    attr_reader :streams_model

    # The widget which controls the data stream => display mapping, and display
    # control
    attr_reader :ui_displays
    # The widget which hold the replay controls (play, pause, ...)
    attr_reader :ui_controls

    KEY_GOTO = Qt::KeySequence.new('g')
    
    # True if we should start playing right away
    attr_accessor :play_now
    # The log directory, or Roby.app.log_dir
    attr_accessor :log_dir
    # Set to a time at which we should go to
    attr_accessor :initial_time
    # A set of procs which are to be called to set up the display
    attr_accessor :initial_setup

    def initialize
	super()
	@play_speed    = 1.0
	@play_now      = nil
	@logdir        = nil
	@goto          = nil
	@initial_setup = []

	# Create the vertical layout for this window
	central_widget = Qt::Widget.new(self)
	layout = Qt::VBoxLayout.new(central_widget)
	layout.spacing = 6
	layout.margin  = 0

	# add support for the data streams and display setup
	@streams = Array.new
	@streams_model = OfflineStreamListModel.new(streams)
	displays_holder = Qt::Widget.new(central_widget)
	layout.add_widget displays_holder
	@ui_displays = Ui_DataDisplays.new
	ui_displays.setupUi(displays_holder)
	ui_displays.streams.model = streams_model
	connect(ui_displays.add_stream, SIGNAL("clicked()"), self, SLOT("add_stream()"))
	connect(ui_displays.remove_stream, SIGNAL("clicked()"), self, SLOT("remove_stream()"))
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

    def displayed_streams
	streams.find_all { |s| !s.displays.empty? }
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

	displayed_streams.each { |s| s.prepare_seek(time) }
	if !time || time == Time.at(0)
	    min, max = displayed_streams.inject([nil, nil]) do |(min, max), stream|
		stream_min, stream_max = stream.range
		if !min || stream_min < min
		    min = stream_min
		end
		if !max || stream_max > max
		    max = stream_max
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
	displayed_streams.
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
	displayed_streams.inject(timeline = []) do |timeline, s| 
	    if s.next_step_time
		timeline << [s.next_step_time, s]
	    end
	    timeline
	end

	if timeline.empty?
	    stop
	    return
	end

	updated_streams = Set.new

	timeline.sort_by { |t, _| t }
	while !timeline.empty? && timeline[0][0] <= max_time
	    timeline.sort_by { |t, _| t }
	    @time, stream = timeline.first

	    stream.advance
	    updated_streams << stream
	    if next_time = stream.next_step_time
		timeline[0] = [next_time, stream]
	    else
		timeline.shift
	    end
	end

	updated_streams.each do |stream|
	    stream.update_display
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

    def add_stream(stream = nil)
	streams_model.add_new(stream)
    end
    slots 'add_stream()'

    def remove_stream
	index = ui_displays.streams.current_index.row
	streams.removeRow(index, Qt::ModelIndex.new)
    end
    slots 'remove_stream()'

    def add_display(kind = nil)
	display  = ui_displays.add_display(streams_model, kind)
	shortcut = Qt::Shortcut.new(KEY_GOTO, display.main)
	connect(shortcut, SIGNAL('activated()'), self, SLOT('goto()'))
	@shortcuts << shortcut
	display
    end
    slots 'add_display()'

    def self.setup(argv)
	replay = self.new

	parser = OptionParser.new do |opt|
	    opt.separator "Common options"
	    opt.on("--logdir=DIR", String, "the log directory in which we initialize the data streams") do |dir|
		replay.log_dir = dir
	    end
	    opt.on("--play", "start playing after loading the event log") do 
		replay.play_now = true
	    end

	    opt.separator "GUI-related options"
	    opt.on("--speed=SPEED", Integer, "play speed") do |speed|
		replay.play_speed = speed
	    end
	    opt.on("--goto=TIME", String, "go to TIME before playing normally. Time is given relatively to the simulation start") do |goto| 
		replay.initial_time = Time.from_hms(goto)
	    end
	    opt.on("--relations=REL1,REL2", Array, "create a relation display with the given relations") do |relations|
		relations.map! do |relname|
		    rel = (Roby::TaskStructure.relations.find { |rel| rel.name =~ /#{relname}/ }) ||
			(Roby::EventStructure.relations.find { |rel| rel.name =~ /#{relname}/ })

			unless rel
			    STDERR.puts "Unknown relation #{relname}. Available relations are:"
			    STDERR.puts "  Tasks: " + Roby::TaskStructure.enum_for(:each_relation).map { |r| r.name.gsub(/.*Structure::/, '') }.join(", ")
			    STDERR.puts "  Events: " + Roby::EventStructure.enum_for(:each_relation).map { |r| r.name.gsub(/.*Structure::/, '') }.join(", ")
			    exit(1)
			end

		    rel
		end

		replay.initial_setup << lambda do |gui|
		    relation_display = gui.add_display('Relations')
		    relations.each do |rel|
			relation_display.enable_relation(rel)
		    end
		end
	    end
	end
	args = argv.dup
	parser.parse!(args)

	yield(replay, parser, args) if block_given?

	replay
    end

    def setup
	initial_setup.each do |prc|
	    prc.call(self)
	end

	show
	if initial_time
	    seek(nil)
	    seek(first_sample + (initial_time - Time.at(0)))
	end

	if play_now
	    ui_controls.play.checked = true
	end
    end
end

if $0 == __FILE__
    a = Qt::Application.new(ARGV)
    w = Replay.new
    w.show
    a.exec
end

