require 'roby/support'

module Roby
    class Control
	include Singleton
	def self.method_missing(name, *args, &block)
	    instance.send(name, *args, &block)
	end

	# The main plan (i.e. the one which is being executed)
	attr_accessor :main

	@event_processing = []
	class << self
	    # List of procs which are called at each event cycle
	    attr_reader :event_processing
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
	    require 'roby/drb'
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

	# Main event loop. Valid options are
	# cycle::   the cycle duration in seconds (default: 0.1)
	# drb:: address of the DRuby server if one should be started (default: nil)
	# detach::  if true, start in its own thread (default: false)
	# control_gc::	if true, automatic garbage collection is disabled but
	#		GC.start is called at each event cycle
	def run(options)
	    options = validate_options options, 
		:drb => nil, :cycle => 0.1, :detach => false, 
		:control_gc => false
		
	    if options[:detach]
		self.thread = Thread.new { run(options.merge(:detach => false)) }
		STDERR.puts self
		STDERR.puts self.thread
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
		    sleep(cycle - cycle_duration)
		end
	    end

	rescue Interrupt
	    STDERR.puts "Interrupted"

	rescue Exeception => e
	    STDERR.puts "Control quitting because of unhandled exception #{e.message}(#{e.class})"

	ensure
	    GC.enable
	    DRb.stop_service if options[:drb]
	    @thread = nil unless options[:detach]
	end

	# If the event thread has been started in its own thread, 
	# wait for it to terminate
	def join
	    thread.join if thread
	end

	def quit
	    thread.raise Interrupt if thread
	end

	def running?; !!@thread end
    end
end

