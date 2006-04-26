require 'roby/task'
require 'roby/drb'

module Roby
    class EventStructureDisplay < DRbRemoteDisplay
	include Singleton

	DEFAULT_URI = 'druby://localhost:10001'
	def self.service; instance.service end
	def self.start_service(uri = DEFAULT_URI)
	    Roby::Task.include TaskHooks
	    Roby::EventGenerator.include RelationHooks

	    instance.start_service(uri) do
		require 'roby/display/event-structure-server'
		Roby::EventStructureDisplayServer.new
	    end
	end
	
	module TaskHooks
	    # Display the start and stop events for each task created
	    def initialize(*args)
		super if defined? super

		STDERR.puts "new task #{self.model.name}"

		return unless server = EventStructureDisplay.service
		STDERR.puts "bla"
		server.event(event(:start))
		server.event(event(:stop))
	    end
	end

	module RelationHooks
	    def added_child_object(to, type, info)
		super if defined? super

		return unless server = EventStructureDisplay.service
		return unless EventStructure::CausalLinks.include?(type)
		server.add(self, to)
	    end
	end
    end
end

if $0 == __FILE__
    STDOUT.sync = true

    TaskMockup = Class.new(Roby::Task) do
	event :start, :command => true
	event :stop
	on :start => :stop
    end

    def task_mockup(name)
	t = TaskMockup.new
	t.model.instance_eval do
	    singleton_class.class_eval do
		define_method(:name) { name }
	    end
	end

	t
    end

    def fill(state_display)
	t1 = task_mockup("a_very_long_name")
	t2 = task_mockup("another_long_name")
	t3 = task_mockup("t3")
		
	f = Roby::ForwarderGenerator.new(t1.event(:start), t2.event(:start))
	t1.event(:stop).on t3.event(:start)
	puts "End"
    end

    # Slow down the event propagation so that we see the display being updated
    module SlowEventPropagation
	def calling(context)
	    super if defined? super
	    sleep(0.1)
	end

	def fired(event)
	    super if defined? super
	    sleep(0.1)
	end

	def signalling(event, to)
	    super if defined? super
	    sleep(0.1)
	end
    end
    Roby::EventGenerator.include SlowEventPropagation

    begin
	server = Roby::EventStructureDisplay.start_service
	fill(server)
	sleep(10)
    rescue Exception => e
	puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
    end
end

