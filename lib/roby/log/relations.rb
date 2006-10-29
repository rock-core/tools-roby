require 'roby/log/logger'
require 'roby/log/drb'

module Roby::Display
    class Relations < DRbRemoteDisplay
	class << self
	    def connect(options = {})
		if !(relations = options.delete(:relations))
		    raise ArgumentError, "no relation given"
		end

		colors = case relations
			 when Array then Hash[*relations.zip([]).flatten]
			 when Hash then relations
			 else { relations => nil }
			 end

		instance = Relations.new(colors.keys)
		Roby::Log.loggers << instance
		instance.connect("relations", options)

		colors = colors.map { |r, c| [r.name, c] }
		instance.display.send('colors=', colors)
		instance
	    end
	end

	attr_reader :relations
	def initialize(relations)
	    @relations = relations
	end

	def disconnected
	    super
	    Roby::Log.loggers.delete(self)
	end

	def task_initialize(time, task, start, stop)
	    display_thread.task_initialize(display, time, task, start, stop)
	end

	STATE_EVENTS = [:start, :success, :failed]
	def generator_fired(time, event)
	    generator = event.generator
	    return unless generator.respond_to?(:symbol)
	    if STATE_EVENTS.include?(generator.symbol)
		display_thread.state_change(display, generator.task, generator.symbol)
	    end
	end

	def finalized_task(time, plan, task)
	    display_thread.state_change(display, task, :finalized)
	end

	[:added_task_relation, :added_event_relation, :removed_task_relation, :removed_event_relation].each do |m|
	    define_method(m) do |time, type, from, to, *args| 
		if relations.find { |rel| rel.name == type }
		    display_thread.send(m, display, time, type, from, to)
		end
	    end
	end
    end
end


