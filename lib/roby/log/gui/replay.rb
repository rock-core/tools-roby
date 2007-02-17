require 'Qt4'
require 'roby/log/gui/replay_ui'
require 'roby/log/gui/relations'

class Replay < Qt::MainWindow
    DISPLAYS = {
	'Relations' => Ui::RelationsConfig
    }
    attr_reader :displays

    attr_reader :ui
    def initialize
	super()
	@ui = Ui_Replay.new
	ui.setupUi(self)
	@displays = Hash.new
	@display_number = 0
	connect(ui.display_add, SIGNAL("clicked()"), self, SLOT("add_display()"))
    end

    def allocate_display_number
	@display_number += 1
    end

    def add_display
	kind = ui.display_types.current_text

	w  = Qt::Widget.new
	w_ui = DISPLAYS[kind].new
	display = w_ui.setupUi(w)

	name = "#{kind}##{allocate_display_number}"
	idx  = ui.displays.add_item(w, name)
	ui.displays.current_index = idx

	displays[w_ui] = display
	Roby::Log.loggers << display
	display.view.window_title = "#{window_title}: #{name}"
	display.view.show
    end
    slots 'add_display()'
end

if $0 == __FILE__
    a = Qt::Application.new(ARGV)
    w = Replay.new
    w.show
    a.exec
end

