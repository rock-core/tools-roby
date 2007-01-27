require 'Qt'
module Roby::Display
    class DRbDisplayServer < Qt::Object
	attr_reader :displays, :main_window, :tabs

	# Starts a new server listening at +uri+
	def initialize(uri = nil)
	    super()

	    @displays = Hash.new

	    if uri
		DRb.stop_service
		DRb.start_service(uri, self)
	    end

	    @updater = Qt::Timer.new(self, "timer")
	    @updater.connect(@updater, SIGNAL('timeout()'), self, SLOT('update()'))
	    # We MUST have the timer running at all times. Otherwise, DRb thread never
	    # gets executed
	    @updater.start(100)
	    enable_updates

	    @display_id = 0
	end

	def add(name)
	    display = yield
	    display.server = self

	    display.main_window.set_name name
	    display.main_window.show
	    display
	end
	private :add

	def new_id
	    @display_id += 1
	end

	# Returns a display of the right kind and name. If the display
	# already exists, it is returned. Otherwise, it is created. +kind+
	# can be either 'relations' or 'execution_state'.
	def get(from, kind, name)
	    kind = kind.to_s
	    name = "#{kind} (#{from}:#{new_id})" if !name

	    unless display = displays[ [kind, name] ]
		begin
		    require "roby/log/#{kind.underscore}/server"
		rescue LoadError
		    require "roby/log/#{kind.underscore.gsub('_', '-')}-server"
		end
		klass_name = "#{kind.classify}Server"
		klass = Roby::Display.constant(klass_name)

		display = displays[ [kind, name] ] = add(name) do
		    klass.new(nil)
		end
	    end

	    display.main_window.show
	    display

	rescue NameError => e
	    raise unless e.name.to_s == klass_name
	    raise ArgumentError, "no such display type #{klass_name}"
	end

	# Deletes display +display+
	def delete(display)
	    (k, n), _ = displays.find { |k, d| d == display }
	    return if !k
	    displays.delete( [k, n] )
	    display.main_window.hide
	end

	def demux(commands)
	    @demuxing = true
	    commands.each do |name, display, *args| 
		if displays.find { |_, d| d == display }
		    block = args.pop
		    display.send(name, *args, &block) 
		end
	    end

	ensure
	    @demuxing = false
	end

	def update
	    Thread.pass

	    while @demuxing
		Thread.pass
	    end
	    if update?
		displays.each_value do |d| 
		    if d.respond_to?(:update) && d.changed? 
			d.changed = false
			d.update
		    end
		end
	    end
	end
	slots "update()"

	def enable_updates
	    @update = true
	    displays.each_value do |d|
		d.enable_updates if d.respond_to?(:enable_updates)
	    end
	end
	def disable_updates
	    @update = false 
	    displays.each_value do |d|
		d.disable_updates if d.respond_to?(:disable_updates)
	    end
	end
	def update?; @update end
    end
end
    

