require 'roby'
require 'utilrb/exception/full_message'

require 'drb'
require 'set'

module Roby
    class Aborting < RuntimeError
	attr_reader :all_exceptions
	def initialize(exceptions); @all_exceptions = exceptions end
	def message
	    "#{super}\n  " +
		all_exceptions.
		    map { |e| e.exception.full_message }.
		    join("\n  ")
	end
    end

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
	    @quit = 0
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
	    exceptions = {}
	    Control.structure_checks.each do |prc|
		new_exceptions = nil
		Propagation.gather_exceptions { new_exceptions = prc.call(plan) }
		next unless new_exceptions

		[*new_exceptions].each do |e, tasks|
		    if e = Propagation.to_execution_exception(e)
			exceptions[e] = tasks
		    end
		end
	    end
	    exceptions
	end

	def reraise(exceptions)
	    raise Aborting.new(exceptions)
	end

	# Process the pending events. Returns a [cycle, server, processing]
	# array which are the duration of the whole cycle, the handling of
	# the server commands and the event processing
	def process_events(timings = {}, do_gc = false)
	    Thread.critical = true
	    Thread.current[:application_exceptions] = []

	    timings[:real_start] = Time.now

	    # Gather new events and propagate them
	    events_errors = Propagation.propagate_events(Control.event_processing)
	    timings[:events] = Time.now

	    # HACK: events_exceptions is sometime nil here. It shouldn't
	    events_errors ||= []

	    # Propagate exceptions that came from event propagation
	    events_errors = Propagation.propagate_exceptions(events_errors)
	    timings[:events_exceptions] = Time.now

	    # Generate exceptions from task structure
	    structure_errors = structure_checking
	    timings[:structure_check] = Time.now
	    structure_errors = Propagation.propagate_exceptions(structure_errors)
	    timings[:structure_check_exceptions] = Time.now

	    # Get the remaining problems in the plan structure, and act on it
	    fatal_structure_errors = structure_checking
	    fatal_errors = fatal_structure_errors.to_a + events_errors
	    timings[:fatal_structure_errors] = Time.now
	    # Get the list of tasks we should kill because of fatal_errors
	    kill_tasks = fatal_errors.inject(ValueSet.new) do |kill_tasks, (e, tasks)|
		if tasks
		    [*tasks].each do |parent|
			new_tasks = parent.reverse_generated_subgraph(TaskStructure::Hierarchy)
			Control.fatal_exception(e, new_tasks)
			kill_tasks.merge(new_tasks)
		    end
		else
		    new_tasks = e.task.reverse_generated_subgraph(TaskStructure::Hierarchy)
		    Control.fatal_exception(e, new_tasks)
		    kill_tasks.merge(new_tasks)
		end
	    end

	    plan.garbage_collect(kill_tasks)
	    timings[:end] = timings[:garbage_collect] = Time.now

	    if do_gc
		GC.force
		timings[:end] = timings[:ruby_gc] = Time.now
	    end

	    if abort_on_exception && !quitting? && !(structure_checking.empty? && events_errors.empty?)
		reraise(fatal_errors.to_a)
	    end
	    
	    application_errors = Thread.current[:application_exceptions]
	    Thread.current[:application_exceptions] = nil
	    application_errors.each do |(event, origin), error|
		Roby.application_error(event, origin, error)
	    end

	    timings

	ensure
	    Thread.critical = false
	    Thread.current[:application_exceptions] = nil
	end

	class << self
	    attribute(:process_once) { Queue.new }
	    def call_once # :nodoc:
		while (p = process_once.pop(true) rescue nil)
		    Propagation.gather_exceptions { p.call }
		end
	    end
	    Control.event_processing << Control.method(:call_once)

	    # Call block once before event processing
	    def once(&block); process_once.push lambda(&block) end
	    # Call +block+ at each cycle
	    def each_cycle(&block); Control.event_processing << lambda(&block) end


	    attribute(:process_every) { Array.new }
	    # Call +block+ every +duration+ seconds. Note that +duration+ is
	    # round up to the cycle size (time between calls is *at least* duration)
	    def every(duration, &block)
		Control.once do
		    process_every << [lambda(&block), nil, duration]
		end
	    end

	    def call_every # :nodoc:
		now = Time.now
		process_every.each do |block, last_call, duration|
		    if !last_call || (now - last_call) > duration
			Propagation.gather_exceptions { block.call }
			last_call = now
		    end
		end
	    end
	    Control.event_processing << Control.method(:call_every)
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

	    last_stop_count = 0
	    @quit = 0
	    loop do
		begin
		    if quitting?
			return if forced_exit?
			plan.keepalive.dup.each { |t| plan.auto(t) }
			plan.force_gc.merge( plan.missions )

			remaining = plan.known_tasks.find_all { |t| Plan.can_gc?(t) }
			if last_stop_count != remaining.size
			    if last_stop_count == 0
				Roby.info "control quitting. Waiting for #{remaining.size} tasks to finish:\n  #{remaining.join("\n  ")}"
			    else
				Roby.info "waiting for #{remaining.size} tasks to finish:\n  #{remaining.join("\n  ")}"
			    end
			    last_stop_count = remaining.size
			end
			return if remaining.empty?
		    end

		    while Time.now > timings[:start] + cycle
			timings[:start] += cycle
		    end
		    timings = process_events(timings, control_gc)
		rescue Exception => e
		    unless quitting?
			STDERR.puts "Control quitting because of unhandled exception"
			STDERR.puts e.full_message
			quit
		    end
		end
		    
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

	ensure
	    if Thread.current == self.thread
		# reset the options only if we are in the control thread
		@thread = nil
		GC.enable if control_gc && !already_disabled_gc
		Control.finalizers.each { |blk| blk.call }
	    end
	end

	@finalizers = []
	def self.finalizers; @finalizers end

	# True if the control thread is currently quitting
	def quitting?; @quit > 0 end
	# True if the control thread is currently quitting
	def forced_exit?; @quit > 1 end
	# Make control quit
	def quit; @quit += 1 end

	# Called at each cycle end
	def cycle_end(timings); super if defined? super end

	# If the event thread has been started in its own thread, 
	# wait for it to terminate
	def join
	    thread.join if thread
	rescue Interrupt
	    Roby.info "received interruption request"
	    quit
	    retry
	end

	attr_reader :cycle_index

	# Hook called when a set of tasks is being killed because of an exception
	def self.fatal_exception(error, tasks); super if defined? super end
	# Hook called when an exception +e+ has been handled by +task+
	def self.handled_exception(e, task); super if defined? super end
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

    # Exception raised when a mission has failed
    class MissionFailedError < TaskModelViolation
	alias :mission :task
	def message
	    "mission #{mission} failed with failed(#{mission.event(:failed).last.context})\n#{super}"
	end
    end
    # Get all missions that have failed
    def self.check_failed_missions(plan)
	result = []
	plan.missions.each do |task|
	    result << MissionFailedError.new(task) if task.failed?
	end
	result
    end
    Control.structure_checks << method(:check_failed_missions)
end

require 'roby/propagation'
