
module Roby::Log
    class DataStream
	attr_reader :id
	attr_reader :name
	attr_reader :type

	def initialize(name, type)
	    @id   = object_id
	    @name = name
	    @type = type
	    @displays = Array.new
	end

	# The set of displays attached to this stream
	attr_reader :displays

	# Clear the stream displays
	def clear
	    displays.each { |d| d.clear }
	end

	# Update the displays
	def update_display
	    displays.each do |d| 
		d.update
	    end
	end

	# Attach a new display for this stream
	def add_display(display)
	    if old = display.data_stream
		display.data_stream.remove_display(display)
	    end
	    displays << display
	    display.data_stream = self
	    # initialize_display(display)
	end

	# Remove a display from this stream
	def remove_display(display)
	    display.clear
	    display.data_stream = nil
	    displays.delete(display)
	end
    end
end

