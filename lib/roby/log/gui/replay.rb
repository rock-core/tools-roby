require 'Qt4'
require 'roby/app'
require 'optparse'

require 'roby/log/event_stream'
require 'roby/log/gui/replay_controls'
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
            newstreams = Roby.app.data_streams_of(newfiles)
	    if !newstreams.empty?
                newstreams.each do |s|
                    s.open
                end
		return newstreams
	    else
		Qt::MessageBox.warning nil, "Add data stream", "Cannot determine data stream type for #{newfiles.join(", ")}"
		return
	    end
	end
    end
end

class Replay < Qt::MainWindow
    attr_reader :streams
    attr_reader :streams_model

    # The widget which controls the data stream => display mapping, and display
    # control
    attr_reader :ui_displays
    # The widget which hold the replay controls (play, pause, ...)
    attr_reader :ui_controls

    # The set of bookmarks as a name => time map
    attr_reader :bookmarks

    KEY_GOTO = Qt::KeySequence.new('g')
    
    # True if we should start playing right away
    attr_accessor :play_now
    # The log directory, or Roby.app.log_dir
    attr_accessor :log_dir
    # Set to a time at which we should go to
    attr_accessor :initial_time
    # A set of procs which are to be called to set up the display
    attr_accessor :initial_setup
    # Set to true if we are playing some data right now
    attr_predicate :running?, true

    def initialize
	super()
	@play_speed    = 1.0
	@play_now      = nil
	@logdir        = nil
	@goto          = nil
	@initial_setup = []
	@bookmarks     = Hash.new

	# Create the vertical layout for this window
	central_widget = Qt::Widget.new(self)
	self.central_widget = central_widget
	layout = Qt::VBoxLayout.new(central_widget)
	layout.spacing = 6
	layout.margin  = 0

	# Add support for the data streams and display setup
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
	@ui_controls = Ui::ReplayControls.new
	ui_controls.setupUi(self, controls_holder)
	layout.add_widget controls_holder
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
	streams.find_all do |s| 
	    s.displayed?
	end
    end

    # Time of the first known sample
    attr_reader :first_sample
    # Time of the last known sample
    attr_reader :last_sample

    def seek(time, integrate = true)
	if time && !first_sample
	    seek(nil) 
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

            if min
                ui_controls.progress.minimum = min.to_i
                ui_controls.progress.maximum = max.to_i
                ui_controls.update_bookmarks_menu
            else
                ui_controls.progress.minimum = 0
                ui_controls.progress.maximum = 1
            end
	else
	    play_until time, integrate
	end

	update_time_display
    end

    def update_time_display
        if first_sample
            ui_controls.time_lcd.display(((self.time - first_sample) * 1000.0).round / 1000.0)
            ui_controls.progress.value = self.time.to_i
        else
            ui_controls.time_lcd.display(0)
            ui_controls.progress.value = 0
        end
    end

    attr_reader :time

    def next_time
	displayed_streams.
	    map { |s| s.next_time }.
	    compact.min 
    end

    BASE_TIME_SLICE = 0.5
    attr_reader :play_timer, :play_speed
    def play
	seek(nil) unless first_sample

	@play_timer = Qt::Timer.new(self)
	connect(play_timer, SIGNAL("timeout()"), self, SLOT("play_step_timer()"))
	play_timer.start(Integer(time_slice * 1000))
    end

    def stop
        self.running = false
	if play_timer
	    ui_controls.play.checked = false
	    play_timer.stop
	    @play_timer = nil
	end
    end

    def play_step
	seek(nil) unless first_sample
       	play_until(next_time) 
    end

    def play_step_timer
	start = Time.now
	play_until(time + time_slice * play_speed)
    end
    slots 'play_step_timer()'

    def play_next_nonempty
        self.running = true
        while running? && !play_step
        end
    end
    
    def play_until(max_time, integrate = false)
	start_at = Time.now
	displayed_streams.inject(timeline = []) do |timeline, s| 
	    if s.next_time
		timeline << [s.next_time, s]
	    end
	    timeline
	end

	if timeline.empty?
	    stop
	    return
	end

        needs_display = Set.new
	updated_streams = Set.new

	timeline.sort_by { |t, _| t }
	while !timeline.empty? && (timeline[0][0] - max_time) < 0.001
	    @time, stream = timeline.first

            unless integrate
                if stream.clear_integrated 
                    needs_display << stream
                end
            end

	    if stream.advance
                needs_display << stream
                updated_streams << stream
            end

	    if next_time = stream.next_time
		timeline[0] = [next_time, stream]
	    else
		timeline.shift
	    end
	    timeline.sort_by { |t, _| t }
	end

	replayed = Time.now

	needs_display.each do |stream|
	    stream.display
	end

	STDERR.puts "replay #{replayed - start_at}, display #{Time.now-replayed}"

	if timeline.empty? then stop
	else @time = max_time
	end

	if time > last_sample
	    @last_sample = time

	    time_display = time.to_i
	    if ui_controls.progress.maximum < time_display
		ui_controls.progress.maximum = (first_sample + (last_sample - first_sample) * 4 / 3).to_i
	    end
	end
	update_time_display
        !updated_streams.empty?

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
	ui_displays.add_display(streams_model, kind)
    end
    slots 'add_display()'

    def self.setup(argv)
	replay = self.new

	parser = OptionParser.new do |opt|
            opt.on('--require=FILE', '-r FILE', String, 'load this file at startup') do |file|
                require file
            end
	    Ui_DataDisplays::DISPLAYS.each_value do |config_ui|
		config_ui.setup_optparse(opt, replay)
	    end

	    opt.on("--logdir=DIR", String, "the log directory in which we initialize the data streams") do |dir|
		replay.log_dir = dir
	    end
	    opt.on("--play", "start playing after loading the event log") do 
		replay.play_now = true
	    end

	    opt.on("--speed=SPEED", Integer, "play speed") do |speed|
		replay.play_speed = speed
	    end
	    opt.on("--goto=TIME", String, "go to TIME before playing normally. Time is given relatively to the simulation start") do |goto| 
		replay.initial_time = goto
	    end
	    opt.on('--bookmarks=FILE', String, "load the bookmarks in FILE") do |file|
		replay.ui_controls.load_bookmarks(file)
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

	    seek_time = if initial_time[0] == ?@
			    Time.from_hms(initial_time[1..-1])
			else
			    first_sample + (Time.from_hms(initial_time) - Time.at(0))
			end
	    seek(seek_time, false)
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

