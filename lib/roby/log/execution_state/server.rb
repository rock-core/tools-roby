require 'Qt'
require 'roby/log/style'

module Roby::Display
    class ExecutionStateServer < Qt::Object
	attr_reader :canvas, :main_window
	def initialize(root_window)
	    super

	    @canvas = ExecutionStateCanvas.new
	    @main_window = Qt::Splitter.new(Qt::Vertical, root_window)
	    
	    @pending = EventList.new(@main_window)
	    @view   = Qt::CanvasView.new(@canvas, @main_window)

	    @hidden = true
 	end

	def hidden?; @hidden end
	def hide
	    @main_window.hide
	    @hidden = true
	end
	def show
	    @main_window.show
	    @hidden = false
	end

	def generator_calling(time, event_generator, context)
	    changed!
	    @pending.generator_calling(time, event_generator, context)
	    @canvas.generator_calling(time, event_generator, context)
	end

	def generator_fired(time, event)
	    changed!
	    @pending.generator_fired(time, event)
	    @canvas.generator_fired(time, event)
	end

	def generator_signalling(time, event, generator)
	    changed!
	    @pending.generator_signalling(time, event, generator)
	    @canvas.generator_signalling(time, event, generator)
	end

	#def postponed(time, generator, wait_for, reason)
	#    @pending.postponed(time, generator, wait_for, reason)
	#end
    end
end

require 'roby/log/execution_state/event-list'
require 'roby/log/execution_state/canvas'

