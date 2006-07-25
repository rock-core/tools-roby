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
		raise NotImplemetedError, "there is already a plan running"
	    else
		@main = plan
	    end
	    self
	end

	# Call +event+ in the context of the event loop
	def call(event, context)
	    @thread.send_to(event, :call, context)
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
	    DRb.start_service(drb_uri, Server.new)
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

	# Main event loop. +cycle+ is the expected polling cycle duration
	# in seconds. A DRb server is started if +drb_uri+ is non-nil and is
	# terminated when #run returns. The event loop is started in its own 
	# thread if +own_thread+ is true.
	def run(drb_uri = nil, cycle = 0.1, own_thread = false)
	    if own_thread
		Thread.new { run(drb_uri, cycle, false) }
		return
	    end

	    @thread = Thread.current

	    drb(drb_uri) if drb_uri
	    cycle_start, cycle_server, cycle_handlers = nil
	    GC.disable
	    GC.start

	    yield if block_given?
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
	    if drb_uri
		DRb.stop_service
	    end
	    puts "Quitting"

	ensure
	    GC.enable
	    @thread = nil unless own_thread
	end

	# If the event thread has been started in its own thread, 
	# wait for it to terminate
	def join
	    @thread.join if @thread
	end

	def quit
	    @thread.raise Interrupt if @thread
	end

	def running?; !!@thread end
    end
end

