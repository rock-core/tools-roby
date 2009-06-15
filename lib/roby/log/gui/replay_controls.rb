require 'roby/log/gui/replay_controls_ui'

class Ui::ReplayControls
    attr_reader :replay

    attr_reader :bookmarks_menu
    attr_reader :bookmarks_actions
    attr_reader :bookmarks_file
    attr_reader :bookmarks_start_mark

    KEY_GOTO = Qt::KeySequence.new('g')

    def load_bookmarks(file = nil)
	file ||= Qt::FileDialog.get_open_file_name replay, "Load bookmarks"
	unless !file || file.empty?
	    replay.bookmarks.clear

	    list = File.open(file) { |io| YAML.load(io) }
	    list.each do |name, times|
		replay.bookmarks[name] = times.map { |t| Time.from_hms(t) if t }
	    end
	    update_bookmarks_menu

	    @bookmarks_file = file
	    actionBookmarksSave.enabled = true
	end
    end

    def save_bookmarks_as
	file = Qt::FileDialog.get_save_file_name replay, "Save bookmarks"
	unless !file || file.empty?
	    @bookmarks_file = file
	    actionBookmarksSave.enabled = true
	    save_bookmarks
	end
    end

    def save_bookmarks
	data = replay.bookmarks.inject(Hash.new) do |data, (name, times)|
	    data[name] = times.map { |t| t.to_hms if t }
	    data
	end
	File.open(bookmarks_file, 'w') do |io|
	    YAML.dump(data, io)
	end
    end


    def update_bookmarks_menu
	bookmarks_actions.each do |action|
	    bookmarks_menu.remove_action action
	end
	bookmarks_actions.clear

	bookmarks = replay.bookmarks.sort_by { |name, time| time }
	bookmarks.unshift(["Mark", [bookmarks_start_mark, nil]]) if bookmarks_start_mark

	bookmarks.each do |name, range|
	    start_time, end_time = if replay.first_sample
				       # Handle sub-millisecond rounding effects
				       range.map do |t| 
					   if t
					       ((t - replay.first_sample) * 1000).round / 1000.0
					   end
				       end
				   else 
				       range.map { |t| t.to_hms if t }
				   end

	    display = if start_time && end_time
			  "#{start_time} - #{end_time}"
		      else
			  (start_time || end_time).to_s
		      end

	    action = Qt::Action.new "#{name} (#{display})", bookmarks_menu
	    action.connect(SIGNAL(:triggered)) do
		range.each { |t| replay.seek(t) if t }
	    end
	    bookmarks_actions << action
	    bookmarks_menu.add_action action
	end
    end
    
    def setupUi(replay, widget)
	@replay = replay
	super(widget)

	@bookmarks_actions = []
	bookmarks.menu = @bookmarks_menu = Qt::Menu.new
	bookmarks_menu.add_action actionBookmarksSave
	bookmarks_menu.add_action actionBookmarksSaveAs
	bookmarks_menu.add_action actionBookmarksLoad
	bookmarks_menu.add_separator
	bookmarks_menu.add_action actionBookmarksSetMark
	bookmarks_menu.add_action actionBookmarksAdd
	bookmarks_menu.add_separator
	actionBookmarksLoad.connect(SIGNAL(:triggered)) { load_bookmarks }
	actionBookmarksSaveAs.connect(SIGNAL(:triggered)) { save_bookmarks_as }
	actionBookmarksSave.connect(SIGNAL(:triggered)) { save_bookmarks }
	actionBookmarksSetMark.connect(SIGNAL(:triggered)) do
	    @bookmarks_start_mark = replay.time
	    update_bookmarks_menu
	end
	actionBookmarksAdd.connect(SIGNAL(:triggered)) do
	    new_name = Qt::InputDialog.get_text widget, "New bookmark", "Name: "
	    unless new_name && new_name.empty?
		replay.bookmarks[new_name] = [bookmarks_start_mark, replay.time]
		update_bookmarks_menu
	    end
	end
	update_bookmarks_menu

	goto.connect(SIGNAL(:clicked)) do
	    handleGoto
	end
	shortcut = Qt::Shortcut.new(KEY_GOTO, widget)
	shortcut.context = Qt::ApplicationShortcut
	shortcut.connect(SIGNAL(:activated)) do
	    handleGoto
	end

	seek_start.connect(SIGNAL(:clicked)) do
	    replay.seek(nil)
	end
	faster.connect(SIGNAL('clicked()')) do
	    speed = replay.play_speed
	    factor = speed < 1 ? 10 : 1
	    speed = Float(Integer(factor * speed) + 1.0) / factor
	    slower.enabled = (speed > 0.1)
	    replay.play_speed = speed
	end
	slower.connect(SIGNAL('clicked()')) do
	    speed = replay.play_speed
	    factor = speed <= 1 ? 10 : 1
	    speed = Float(Integer(factor * speed) - 1.0) / factor
	    slower.enabled = (speed > 0.1)
	    replay.play_speed = speed
	end
	speed.connect(SIGNAL('editingFinished()')) do
	    begin
		new_speed = Float(speed.text)
		if new_speed <= 0
		    raise ArgumentError, "negative values are not allowed for speed"
		end
		replay.play_speed = new_speed
	    rescue ArgumentError
		Qt::MessageBox.warning nil, "Invalid speed", "Invalid value for speed \"#{ui_controls.speed.text}\": #{$!.message}"
		self.play_speed = play_speed
	    end
	end

	play.connect(SIGNAL("clicked()")) do
	    if play.checked?
		replay.play
	    else
		replay.stop
	    end
	    seek_start.enabled = play_step.enabled = !play.checked?
	end
	play_step.connect(SIGNAL("clicked()")) do
	    replay.play_step
	end
	play_next_nonempty.connect(SIGNAL("clicked()")) do
	    replay.play_next_nonempty
	end
    end

    def handleGoto
	user_time = begin
			user_time = Qt::InputDialog.get_text nil, 'Going to ...', 
					"<html><b>Go to time</b><ul><li>use \'+\' for a relative jump forward</li><li>'-' for a relative jump backwards</li></ul></html>", 
					Qt::LineEdit::Normal, (user_time || @last_goto || "")
			return unless user_time && !user_time.empty?

			@last_goto = user_time
			if user_time =~ /^\s*([\+\-@])(.*)/
			    op = $1
			    user_time = $2
			end
			user_time = Time.from_hms(user_time)

		    rescue ArgumentError
			Qt::MessageBox.warning nil, "Invalid user_time", "Invalid user_time: #{$!.message}", "OK"
			retry
		    end

	if !replay.first_sample
	    replay.seek(nil)
	end
        if !replay.first_sample # no samples at all !
            return
        end

	user_time = if !op
			replay.first_sample + (user_time - Time.at(0))
		    elsif op != "@"
			replay.time.send(op, user_time - Time.at(0))
		    else
			user_time
		    end

	replay.seek(user_time)
    end
end

