
module Roby::Log
    class DataStream
	attr_reader :files
	attr_reader :type
	attr_reader :displays
	def initialize(files, type)
	    @files, @type = files, type
	    @displays = Array.new
	end

	def clear
	    displays.each { |d| d.clear }
	end

	def update_display
	    displays.each do |d| 
		d.update
	    end
	end

	def add_display(display)
	    if old = display.data_stream
		display.data_stream.remove_display(display)
	    end
	    displays << display
	    display.data_stream = self
	    # initialize_display(display)
	end

	def remove_display(display)
	    display.clear
	    display.data_stream = nil
	    displays.delete(display)
	end
    end
end

