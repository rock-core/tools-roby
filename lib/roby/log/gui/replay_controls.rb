require 'roby/log/gui/replay_controls_ui'

class Ui::ReplayControls
    attr_reader :replay

    attr_reader :bookmarks_menu
    attr_reader :bookmarks_actions
    attr_reader :bookmarks_file

    KEY_GOTO = Qt::KeySequence.new('g')

    def load_bookmarks(file = nil)
	file ||= Qt::FileDialog.get_open_file_name replay, "Load bookmarks"
	unless !file || file.empty?
	    replay.bookmarks.clear

	    if !replay.first_sample
		replay.seek(nil)
	    end

	    list = File.open(file) { |io| YAML.load(io) }
	    list.each do |name, time|
		replay.bookmarks[name] = Time.from_hms(time)
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
	data = replay.bookmarks.inject(Hash.new) do |data, (name, time)|
	    data[name] = time.to_hms
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

	replay.bookmarks.sort_by { |name, time| time }.
	    each do |name, time|
		display_time = if replay.first_sample
				   time - replay.first_sample
			       else time.to_hms
			       end

		action = Qt::Action.new "#{name} (#{display_time})", bookmarks_menu
		action.connect(SIGNAL(:triggered)) do
		    replay.seek(time)
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
	bookmarks_menu.add_action actionBookmarksAdd
	bookmarks_menu.add_separator
	actionBookmarksLoad.connect(SIGNAL(:triggered)) { load_bookmarks }
	actionBookmarksSaveAs.connect(SIGNAL(:triggered)) { save_bookmarks_as }
	actionBookmarksSave.connect(SIGNAL(:triggered)) { save_bookmarks }
	actionBookmarksAdd.connect(SIGNAL(:triggered)) do
	    new_name = Qt::InputDialog.get_text widget, "New bookmark", "Name: "
	    unless new_name && new_name.empty?
		replay.bookmarks[new_name] = replay.time
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
		replay.speed = new_speed
	    rescue ArgumentError
		Qt::MessageBox.warning self, "Invalid speed", "Invalid value for speed \"#{ui_controls.speed.text}\": #{$!.message}"
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
    end

    def handleGoto
	user_time = begin
			user_time = Qt::InputDialog.get_text nil, 'Going to ...', 
					"<html><b>Go to time</b><ul><li>use \'+\' for a relative jump forward</li><li>'-' for a relative jump backwards</li></ul></html>", 
					Qt::LineEdit::Normal, (user_time || @last_goto || "")
			return unless user_time && !user_time.empty?

			if user_time =~ /^\s*([\+\-])(.*)/
			    op = $1
			    user_time = $2
			end
			user_time = Time.from_hms(user_time) - Time.at(0)
			@last_goto = user_time

		    rescue ArgumentError
			Qt::MessageBox.warning self, "Invalid user_time", "Invalid user_time: #{$!.message}"
			retry
		    end

	unless replay.first_sample
	    replay.seek(nil)
	end

	user_time = if op
			replay.time.send(op, user_time)
		    else
			replay.first_sample + user_time
		    end

	replay.seek(user_time)
    end
end

