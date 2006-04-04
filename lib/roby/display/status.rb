require 'roby/support'
require 'drb'
require 'Qt'
require 'enumerator'

module Roby
    class PlanDisplay < Qt::Object
	BASE_DURATION = 10000
	BASE_LINES    = 10

	@@display = nil
	def self.method_missing(*args)
	    @@display.send(*args) if @@display
	end

	attr_reader :line_height, :resolution, :start_time, :margin
	attr_reader :canvas, :view
	def initialize
	    super

	    @start_time	    = nil # start time (time of the first event)
	    @resolution	    = BASE_DURATION / 640 # resolution for time axis in ms per pixel
	    @line_height    = 30  # height of a line in pixel
	    standalone_line = Struct.new(:index).new(0)
	    @lines = [standalone_line] # active tasks for each line, the first line is for events not related to a task
	    @tasks	    = Array.new # list of known task objects
	    @margin	    = 10
	    
	    @canvas = Qt::Canvas.new(640, line_height * BASE_LINES + margin * 2)
	    @view   = Qt::CanvasView.new(canvas)

	    @generators = Hash.new
 	end

	def hide
	    @view.hide
	    @@display = nil
	    @updater.stop if @updater
	end
	def show
	    @view.show
	    if !@updater
		@updater = Qt::Timer.new(self, "timer")
		@updater.connect(@updater, SIGNAL('timeout()'), self, SLOT('update()'))
	    end

	    @updater.start(0)
	    @@display = self
	end

	class CanvasTask < Qt::CanvasRectangle
	    attr_accessor :start, :stop
	    attr_reader :task, :index

	    def initialize(display, task, index, &conf)
		@task, @index = task, index
		line_height = display.line_height
		y = (0.2 + index) * line_height
		super(0, y, 0, line_height * 0.6, display.canvas, &conf)
		
		self.brush = Qt::Brush.new(Qt::Color.new('#61d2ff'))
		self.z = -1
		self
	    end
	end

	def line_of(event)
	    if event.respond_to?(:task)
		task = event.task

		# Get the line index for the task
		idx = @lines.enum_for(:each_with_index).find { |r, idx| r.task == task if r.respond_to?(:task) } ||
		    @lines.enum_for(:each_with_index).find { |r, idx| !r } ||
		    [nil, @lines.size]
		idx = idx.last

		# Build the task representation if necessary
		line = (@lines[idx] ||= CanvasTask.new(self, task, idx) { |r| r.visible = true })
		puts "#{event}: #{task} #{line} #{line.index}"
		line
	    else
		@lines[0]
	    end
	end
	def x_of(time)
	    @start_time = time if !start_time
	    x = (time - @start_time) * 1000 / resolution
	    # TODO make sure x is in the canvas
	end

	def new_event(time, generator)
	    x	    = x_of(time)
	    line    = line_of(generator)

	    if line.respond_to?(:task)
		if !line.start
		    line.start = x
		    line.x = x
		end
		line.stop = x
		line.setSize(line.stop - line.start, line.height)
		line.visible = true
		line.brush = Qt::Brush.new(Qt::Color.new('grey'))

		puts "#{line.x} #{line.y} #{line.width} #{line.height}"
	    end
	    
	    y = line.index * line_height + line_height / 2
	    shape = yield(x, y)

	    shape.move(x, y)
	    shape.visible = true
	end

	def pending_event(time, event_generator)
	    new_event(time, event_generator) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, canvas) do |e|
		    e.brush = Qt::Brush.new(Qt::Color.new('lightgrey'))
		end
	    end
	end

	def fired_event(time, event_generator, event)
	    new_event(time, event_generator) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, canvas) do |e|
		    e.brush = Qt::Brush.new(Qt::Color.new('black'))
		end
	    end
	end

	def update()
	    Thread.pass
	    canvas.update
	    view.update
	end
	slots "update()"
    end

    module EventHooks
	def calling(context)
	    super if defined? super
	    @pending << self
	    PlanDisplay.pending_event self
	end

	def fired(event)
	    if event_model = @pending.find { |model| event.model == model }
		@pending.delete(event_model)
		PlanDisplay.fired_event event_model, event
	    end
	end
    end
end

if $0 == __FILE__
    STDOUT.sync = true
    class MessagePoster
	class Quit < RuntimeError; end
	attr_reader :thread

	def initialize(forward_to)
	    @queue = Queue.new
	    @thread = Thread.new do
		begin
		    loop do
			message = @queue.pop
			block = message.pop
			forward_to.send(*message, &block)
		    end
		rescue Quit
		end
	    end
	end
	def method_missing(*args, &block)
	    if Thread.current == @thread
		super
	    else
		args << block
		@queue.push args
	    end
	end
	def quit!
	    @thread.raise Quit
	    @thread.join
	end
    end

    class EventMockup
        attr_reader :name
        Model = Struct.new :symbol
        def initialize(name, terminal = false, task = nil)
	    @name, @terminal, @task = name, terminal, task
	    if task
		def self.task
		    @task
		end
	    end
	end
        def terminal?; @terminal end
        def model; Model.new name.to_sym end
    end
    class TaskMockup
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
	actions.each do |msg, *obj|
	    STDERR.puts "sending #{msg}(#{obj})"
	    state_display.send(msg, Time.now, *obj)
	    sleep(0.1)
	end
    end

    Thread.abort_on_exception = true
    SERVER_URI = 'druby://localhost:9001'
    server_pid = fork do
	a = Qt::Application.new( ARGV )

	display_server = Roby::PlanDisplay.new
	DRb.start_service(SERVER_URI, display_server)
	DRb.thread.priority = 1

	display_server.show
	a.setMainWidget( display_server.view )
	a.exec()
    end

    server = DRbObject.new(nil, SERVER_URI)
    server = MessagePoster.new(server)
    server.thread.priority = -1

    DRb.start_service
    sleep(1)
    fill(server)
end

