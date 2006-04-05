require 'roby/support'
require 'drb'
require 'enumerator'

class Object
    def address
	id = object_id
	if id < 0
	    0xFFFFFFFF + id
	else
	    id
	end
    end
end

module Roby
    class ExecutionStateDisplay
	@@service = nil
	def self.service; @@service end
	def self.start_service(uri = 'druby://localhost:10000')
	    read, write = IO.pipe
	    fork do
		begin
		    require 'roby/display/status-qt'
		    GC.disable
		    a = Qt::Application.new( ARGV )

		    display_server = Roby::ExecutionStateDisplayServer.new
		    DRb.start_service(SERVER_URI, display_server)
		    DRb.thread.priority = 1

		    read.close
		    write.write("OK")

		    display_server.show
		    a.setMainWidget( display_server.view )
		    a.exec()
		rescue Exception => e
		    puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
		end
	    end

	    check = read.read(2)
	    if check != "OK"
		raise "failed to start execution state display server"
	    end

	    DRb.start_service

	    # Get the remote object
	    server = DRbObject.new(nil, uri)
	    @@service = server
	    #@@service = ThreadServer.new(server)
	    #@@service.thread.priority = -1
	    @@service
	end
    end

    module EventHooks
	def calling(context)
	    super if defined? super
	    PlanDisplay.service.pending_event self
	end

	def fired(event)
	    super if defined? super
	    PlanDisplay.service.fired_event self, event
	end
    end

    class EventGenerator
	include EventHooks
    end
end

if $0 == __FILE__
    STDOUT.sync = true
    class EventMockup
	include DRbUndumped 

        attr_reader :name
        Model = Struct.new :symbol
        def initialize(name, terminal = false, task = nil)
	    @name, @terminal, @task = name, terminal, task
	    singleton_class.class_eval { private :task } unless task
	end
	def task
	    puts @task.inspect
	    @task
	end
        def terminal?; @terminal end
        def model; Model.new name.to_sym end
    end
    class TaskMockup
	include DRbUndumped 

        attr_reader :name, :children
        attr_accessor :display_group
        def initialize(name)
            @name = name 
            @children = []
        end
        def bound_events 
            @bound_events ||= [ EventMockup.new(:start, false, self), EventMockup.new(:stop, true, self) ]
        end
	def start_event; bound_events.first end
	def stop_event; bound_events.last end

        Model = Struct.new(:name)
        def model
            m = Model.new
            m.name = name
            m
        end

        def each_child(&iterator); @children.each(&iterator) end
        def each_event(only_bounded, &iterator); bound_events.each(&iterator) end

        def display(view)
            group = Graph.hierarchy(view.canvas, self)
            group.
                translate( group.width / 2, 16 ).
                visible = true
        end
    end

    def fill(state_display)
	forwarder = EventMockup.new("=>")
	task1 = TaskMockup.new('t1')
	task2 = TaskMockup.new('t2')

	actions = [
	    [ :pending_event, forwarder ],
	    [ :fired_event, forwarder, forwarder ],
	    [ :pending_event, task1.start_event ],
	    [ :pending_event, task2.start_event ],
	    [ :fired_event, task2.start_event, task2.start_event ],
	    [ :pending_event, task2.stop_event ],
	    [ :fired_event, task1.start_event, task1.start_event ],
	    [ :fired_event, task2.stop_event, task2.stop_event ]
	]
	puts "#{task1.address.to_s(16)} #{task2.address.to_s(16)}"
	actions.each do |msg, *args|
	    state_display.send(msg, Time.now, *args)
	    sleep(0.1)
	end

	#state_display.thread.join
    end

    begin
	Thread.abort_on_exception = true
	SERVER_URI = 'druby://localhost:9001'
	server = Roby::ExecutionStateDisplay.start_service(SERVER_URI)

	fill(server)
    rescue Exception => e
	puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
    end
end

