require 'roby/log/marshallable'
require 'roby/log/log'
require 'roby/log/drb'

module Roby::Display
    class EventStructure < DRbRemoteDisplay
	include Singleton

	DEFAULT_URI = 'druby://localhost:10001'

	class << self
	    def service; instance.service end
	    def connect(options = {})
		Roby::Log.loggers << instance
		options[:server] ||= DEFAULT_URI
		instance.connect("event_structure", options)
	    end
	end

	def disconnect
	    Roby::Log.loggers.delete(instance)
	end

	def task_initialize(time, task, start, stop)
	    service.task_initialize(time, task, start, stop)
	end

	STATE_EVENTS = [:start, :success, :failed]
	def generator_fired(time, event)
	    generator = event.generator
	    return unless generator.respond_to?(:symbol)
	    if STATE_EVENTS.include?(generator.symbol)
		service.state_change(generator.task, generator.symbol)
	    end
	end

	def added_relation(time, type, from, to, info)
	    if Roby::EventStructure::CausalLinks.subset?(type)
		service.added_relation(time, from, to)
	    end
	end

	def removed_relation(time, type, from, to)
	    if Roby::EventStructure::CausalLinks.subset?(type)
		service.removed_relation(time, from, to)
	    end
	end
    end
end

if $0 == __FILE__
    include Roby
    STDOUT.sync = true

    TaskMockup = Class.new(Roby::Task) do
	event :start, :command => true
	event :stop
	on :start => :stop
    end

    def task_mockup(name)
	t = TaskMockup.new
	t.model.instance_eval do
	    singleton_class.send(:define_method, :name) { name }
	end

	t
    end

    def fill(state_display)
	t1 = task_mockup("a_very_long_name")
	t2 = task_mockup("another_long_name")
	t3 = task_mockup("t3")
		
	f = Roby::ForwarderGenerator.new(t1.event(:start), t2.event(:start))
	t1.event(:stop).on t3.event(:start)

	t4 = task_mockup('t4')
	t4.event(:stop).on t3.event(:start)
	puts "End"
    end

    Roby::EventGenerator.include SlowEventPropagation

    begin
	server = Roby::Display::EventStructure.connect :start => true
	fill(server)
	sleep(10)
    rescue Exception => e
	puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
    end
end

