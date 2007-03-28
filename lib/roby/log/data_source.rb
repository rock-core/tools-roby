
module Roby::Log
    class DataSource
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
	    if old = display.data_source
		display.data_source.remove_display(display)
	    end
	    displays << display
	    display.data_source = self
	    # initialize_display(display)
	end

	def remove_display(display)
	    display.clear
	    display.data_source = nil
	    displays.delete(display)
	end
    end
end

