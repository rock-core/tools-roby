require 'roby/support'
require 'drb'
require 'set'
require 'utilrb/exception/full_message'

module Roby
    class Control
	include Singleton

	# Do not sleep or call Thread#pass if there is less that
	# SLEEP_MIN_TIME time left in the cycle
	SLEEP_MIN_TIME = 0.01

	attr_accessor :abort_on_exception
	attr_accessor :abort_on_application_exception
	attr_accessor :abort_on_framework_exception

	@event_processing	= []
	@structure_checks	= []
	class << self
	    # List of procs which are called at each event cycle
	    attr_reader :event_processing
	    # List of procs to be called for task structure checking
	    #
	    # These should raise exceptions for each problem in the task
	    # structure. The exception *must* respond to #task to know
	    # from which task the problem comes.
	    attr_reader :structure_checks
	end
	attr_reader :plan, :planners

	def initialize
	    super
	    @cycle_index = 0
	    @planners = []
	    @plan     = Plan.new
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
	def disable_propagation
	    if block_given?
		begin
		    Propagation.disable_propagation 
		    yield
		ensure
		    Propagation.enable_propagation 
		end
	    else
		Propagation.disable_propagation 
	    end
	end
	# Enable all event propagation
	def enable_propagation; EventGenerator.enable_propagation end
	# Check if event propagation is enabled or not
	def propagate?; EventGenerator.propagate? end

	# Start a DRuby server on drb_uri
	def drb(drb_uri = nil)
	    require 'roby/control_interface'
	    DRb.start_service(drb_uri, ControlInterface.new(self))
	    Roby.info "Started DRb server on #{drb_uri}"
	end

	# Perform the structure checking step by calling the procs registered
	# in Control::structure_checks. These procs are supposed to return a
	# collection of exception objects, or nil if no error has been found
	def structure_checking
	    # Do structure checking and gather the raised exceptions
	    exceptions = Control.structure_checks.
		map { |prc| prc.call(plan) }.
		flatten

	    exceptions.map! do |error|
		next unless error
		Propagation.to_execution_exception(error)
	    end

	    exceptions.compact!
	    exceptions
	end

	def reraise(exceptions)
	    if !exceptions.empty? && abort_on_exception
		exceptions.each do |e|
		    raise e.exception
		end
	    end
	end

	# Process the pending events. Returns a [cycle, server, processing]
	# array which are the duration of the whole cycle, the handling of
	# the server commands and the event processing
	def process_events(timings = {}, do_gc = false)
	    timings[:real_start] = Time.now

	    # Get the events received by the server and process them
	    Thread.current.process_events
	    timings[:server] = Time.now
	    
	    # Gather new events and propagate them
	    events_exceptions = Propagation.propagate_events(Control.event_processing)
	    timings[:events] = Time.now

	    # Propagate exceptions that came from event propagation
	    events_exceptions = Propagation.propagate_exceptions(events_exceptions)
	    timings[:events_exceptions] = Time.now

	    reraise(events_exceptions) if abort_on_exception

	    # Generate exceptions from task structure
	    structure_exceptions = structure_checking
	    timings[:structure_check] = Time.now
	    structure_exceptions = Propagation.propagate_exceptions(structure_exceptions)
	    timings[:structure_check_exceptions] = Time.now

	    reraise(structure_exceptions) if abort_on_exception

	    # Recheck structure, taking into account the changes from exception handlers
	    fatal_errors = structure_checking
	    # Get the list of tasks we should kill because of fatal_errors
	    kill_tasks = fatal_errors.inject(ValueSet.new) do |kill_tasks, e|
		kill_tasks.merge(e.task.reverse_directed_component(TaskStructure::Hierarchy))
	    end

	    events_exceptions.each do |e|
		kill_tasks.merge(e.trace)
	    end
	    
	    plan.garbage_collect(kill_tasks)
	    timings[:end] = timings[:garbage_collect] = Time.now

	    if do_gc
		GC.force
		timings[:end] = timings[:ruby_gc] = Time.now
	    end

	    timings
	end

	class << self
	    attribute(:process_once) { Queue.new }
	    def call_once
		while (p = process_once.pop(true) rescue nil)
		    Propagation.gather_exceptions { p.call }
		end
	    end
	    Control.event_processing << Control.method(:call_once)

	    # Call block once during event processing
	    def once(&block)
		process_once.push block
	    end
	end


	attr_accessor :thread
	def running?; !!@thread end

	# The cycle length in seconds
	attr_reader :cycle_length

	# Main event loop. Valid options are
	# cycle::   the cycle duration in seconds (default: 0.1)
	# drb:: address of the DRuby server if one should be started (default: nil)
	# detach::  if true, start in its own thread (default: false)
	# control_gc::	if true, automatic garbage collection is disabled but
	#		GC.start is called at each event cycle
	def run(options = {})
	    options = validate_options options, 
		:drb => nil, :cycle => 0.1, :detach => false, 
		:control_gc => false, :log => false

	    @cycle_length = options[:cycle]
	
	    # Start DRb as soon as possible so that the caller knows
	    # that DRb is up when #run returns, event when :detach is true.
	    #
	    # It allows to do
	    #	Control.run :drb => DRB_SERVER, :detach => true
	    #	<do something with DRb>	    
	    drb(options[:drb]) if options[:drb]
	    
	    if options[:detach]
		self.thread = Thread.new { run(options.merge(:detach => false, :drb => nil)) }
		return
	    end
	    self.thread = Thread.current
	    self.thread.priority = 10

	    control_gc = options[:control_gc]
	    if control_gc
		already_disabled_gc = GC.disable
		GC.force
	    end

	    yield if block_given?
	    cycle   = options[:cycle]
	    log	    = options[:log]
	    timings = {}
	    timings[:start] = Time.now
	    loop do
		while Time.now > timings[:start] + cycle
		    timings[:start] += cycle
		end
		timings = process_events(timings, control_gc)
		
		timings[:pass] = timings[:sleep] = timings[:end]
		cycle_duration = timings[:end] - timings[:start]
		if cycle - cycle_duration > SLEEP_MIN_TIME
		    cycle_end(timings)

		    Thread.pass
		    timings[:pass] = Time.now

		    # Take the time we passed in other threads into account
		    sleep_time = cycle - (Time.now - timings[:start])
		    if sleep_time > 0
			sleep(sleep_time) 
			timings[:sleep] = Time.now
		    end
		end

		log << Marshal.dump(timings) if log
		timings[:start] += cycle
	    end

	rescue Interrupt
	    STDERR.puts "Interrupted"

	rescue Exception => e
	    STDERR.puts "Control quitting because of unhandled exception\n#{e.full_message}"

	ensure
	    if Thread.current == self.thread
		# reset the options only if we are in the event thread
		@thread = nil
		DRb.stop_service if options[:drb]
		GC.enable if control_gc && !already_disabled_gc
	    end
	end

	# Called at each cycle end
	def cycle_end(timings); super if defined? super end

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

require 'roby/planning/model'

