require 'Qt'
require 'roby/display/style'

module Roby
    class ExecutionStateDisplayServer < Qt::Object
	attr_reader :canvas, :main_window
	def initialize
	    super

	    @canvas = ExecutionStateCanvas.new
	    @main_window = Qt::Splitter.new(Qt::Vertical)
	    
	    @view   = Qt::CanvasView.new(@canvas, @main_window)
	    @pending = EventList.new(@main_window)

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

	def pending_event(time, event_generator)
	    changed!
	    @pending.pending_event(time, event_generator)
	    @canvas.pending_event(time, event_generator)
	end

	def fired_event(time, event_generator, event)
	    changed!
	    @pending.fired_event(time, event_generator, event)
	    @canvas.fired_event(time, event_generator, event)
	end

	def signalling(time, from, to)
	    changed!
	    @pending.signalling(time, from, to)
	    @canvas.signalling(time, from, to)
	end

	def postponed(time, generator, wait_for, reason)
	    @pending.postponed(time, generator, wait_for, reason)
	end
    end
end

require 'roby/display/execution-state/event-list'
require 'roby/display/execution-state/canvas'

