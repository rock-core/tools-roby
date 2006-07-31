require 'roby/support'
require 'drb'
require 'set'

module Roby
    class Control
	include Singleton

	# The main plan (i.e. the one which is being executed)
	attr_accessor :main

	@event_processing = []
	class << self
	    # List of procs which are called at each event cycle
	    attr_reader :event_processing
	end

	def initialize
	    @cycle_index = 0
	    @keep    = Set.new
	    @garbage = Hash.new
	    @garbage_can  = Set.new
	end

	# Inject +plan+ in +main+
	def insert(plan)
	    if @main
		raise NotImplementedError, "there is already a plan running"
	    else
		send_to_event_loop(self, :do_insert, plan)
	    end
	    self
	end

	def do_insert(plan)
	    @main = plan
	end

	def send_to_event_loop(object, *funcall, &block)
	    if @thread && Thread.current != @thread
		@thread.send_to(object, *funcall, &block)
	    else
		object.send(*funcall, &block)
	    end
	end

	# Call +event+ in the context of the event loop
	def call(event, context)
	    send_to_event_loop(event, :call, context)
	    self
	end

	# Disable all event propagation
	def disable_propagation; EventGenerator.disable_propagation end
	# Enable all event propagation
	def enable_propagation; EventGenerator.enable_propagation end
	# Check if event propagation is enabled or not
	def propagate?; EventGenerator.propagate? end

	# Start a DRuby server on drb_uri
	def drb(drb_uri = nil)
	    DRb.start_service(drb_uri, Control.instance)
	    Roby.info "Started DRb server on #{drb_uri}"
	end

	# Process the pending events. Returns a [cycle, server, processing]
	# array which are the duration of the whole cycle, the handling of
	# the server commands and the event processing
	def process_events
	    # Current time
	    cycle_start = Time.now

	    # Get the events received by the server and process them
	    cycle_server = Time.now
	    Thread.current.process_events
	    
	    # Call event processing registered by other modules
	    cycle_handlers = Time.now
	    Control.event_processing.each { |prc| prc.call }
	    
	    cycle_end = Time.now
	    
	    whole_cycle = cycle_end - cycle_start
	    server_handling = cycle_server - cycle_start
	    processing = cycle_handlers - cycle_server

	    [whole_cycle, server_handling, processing]
	end

	attr_accessor :thread
	def running?; !!@thread end

	# Main event loop. Valid options are
	# cycle::   the cycle duration in seconds (default: 0.1)
	# drb:: address of the DRuby server if one should be started (default: nil)
	# detach::  if true, start in its own thread (default: false)
	# control_gc::	if true, automatic garbage collection is disabled but
	#		GC.start is called at each event cycle
	def run(options = {})
	    options = validate_options options, 
		:drb => nil, :cycle => 0.1, :detach => false, 
		:control_gc => false
		
	    if options[:detach]
		self.thread = Thread.new { run(options.merge(:detach => false)) }
		return
	    end

	    self.thread = Thread.current

	    drb(options[:drb]) if options[:drb]
	    cycle_start, cycle_server, cycle_handlers = nil
	    GC.disable if options[:control_gc]
	    GC.start

	    yield if block_given?
	    cycle = options[:cycle]
	    loop do
		cycle_start = Time.now
		process_events

		GC.start
		cycle_duration = Time.now - cycle_start
		if cycle > cycle_duration
		    Thread.pass
		    sleep(cycle - cycle_duration)
		end
		garbage_mark
		garbage_collect
	    end

	rescue Interrupt
	    STDERR.puts "Interrupted"

	rescue Exception => e
	    STDERR.puts "Control quitting because of unhandled exception #{e.message}(#{e.class})"

	ensure
	    GC.enable
	    DRb.stop_service if options[:drb]
	    @thread = nil unless options[:detach]
	end

	# Tell the controller that this particular task should not be 
	# killed even when it seems that it is not useful anymore
	def protect(task); @keep << task end

	# True if task is protected. See #protect
	def protected?(task); @keep.include?(task) end

	# Tell the controller that +task+ should not be controlled
	# anymore. See Control#protect.
	def unprotect(task); @keep.delete(task) end

	def marked?(task)
	    @garbage[task] || @garbage_can.include?(task)
	end
	def useful?(task)
	    protected?(task) || task.enum_for(:each_parent_task).any? { |task| !task.dead? }
	end

	# Mark tasks for garbage collection. It marks all unused tasks
	# to be killed next time garbage_collect is called
	#
	# If a parent task is marked as being garbage, we *do not*
	# mark its children since the parent task can have a cleanup
	# routine.
	def garbage_mark
	    return unless main

	    # @garbage is a task -> count map which gives the cycle count for which +task+
	    # has not been useful
	    main.each_task { |task| mark_task(task) }
	end
	def mark_task(task)
	    @garbage[task] ||= cycle_index unless useful?(task)
	end

	def garbage_collect
	    return unless main

	    # @garbage_can contains the tasks that are being killed by the garbage collector
	    @garbage.dup.each do |task, cycle_index|
		task.dead!
		@garbage.delete(task)

		if task.running?
		    next if @garbage_can.include?(task)

		    @garbage_can << task
		    task.on(:stop) { @garbage_can.delete(task) }

		    stop = task.event(:stop)
		    stop.call("not useful anymore !") if stop.controlable?

		elsif task.pending?
		    @garbage_can << task

		    task.each_child do |child|
			next if marked?(child)
			mark_task(child) unless useful?(child)
		    end
		end
	    end
	end

	# If the event thread has been started in its own thread, 
	# wait for it to terminate
	def join
	    thread.join if thread
	end

	def quit
	    thread.raise Interrupt if thread
	end
	attr_reader :cycle_index
    end

    class Client < DRbObject
	attr_reader :uri
	def initialize(uri)
	    @uri = uri
	    super(nil, uri)
	end
	def quit
	    super
	rescue DRb::DRbConnError
	    Roby.info "remote server at #{uri} has quit"
	end
    end
end

