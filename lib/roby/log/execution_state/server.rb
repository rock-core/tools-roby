 'Qt'
require 'roby/log/style'

module Roby::Display
    class ExecutionStateServer < Qt::Object
	include DRbDisplayMixin

	attr_reader :canvas, :main_window
	def initialize(root_window)
	    super

	    @canvas = ExecutionStateCanvas.new
	    @main_window = Qt::Splitter.new(Qt::Vertical, root_window)
	    
	    @pending = EventList.new(@main_window)
	    @view   = Qt::CanvasView.new(@canvas, @main_window)
	    @canvas.view = @view

	    @hidden = true
 	end

	def update; @canvas.update end

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

	def clear
	    @pending.clear
	    @canvas.clear
	    changed!
	end

	def cycle_end(time, timings)
	    canvas.ping(time)
	    changed!
	end

	#def postponed(time, generator, wait_for, reason)
	#    @pending.postponed(time, generator, wait_for, reason)
	#end
	
	def enable_updates
	    @view.updates_enabled = true
	    @pending.updates_enabled = true
	end
	def disable_updates
	    @view.updates_enabled = false
	    @pending.updates_enabled = false
	end
    end
end

require 'roby/log/execution_state/event-list'
require 'roby/log/execution_state/canvas'

