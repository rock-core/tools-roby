
module Roby
    class TaskStructureDisplayServer < Qt::Object
	attr_reader :main_window, :canvas
	def initialize(root_window)
	    super

	    @canvas = Qt::Canvas.new
	    @main_window = Qt::CanvasView.new(@canvas, root_window)
	end

	def task(task)
	end
    end
end

