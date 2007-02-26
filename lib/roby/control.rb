require 'roby'
require 'utilrb/exception/full_message'

require 'drb'
require 'set'

module Roby
    # Exception raised when the event loop aborts because of an unhandled
    # exception
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

    # Returns the only one Control object
    def self.control; Control.instance end
    # Returns the executed plan
    def self.plan; Control.instance.plan end

    # This singleton class is the central object: it handles the event loop,
    # event propagation and exception propagation.
    class Control
	include Singleton

	@mutex = Mutex.new
	class << self
	    attr_reader :mutex
	    def synchronize
		if Thread.current[:control_mutex_locked]
		    yield
		else
		    @mutex.synchronize do
			begin
			    Thread.current[:control_mutex_locked] = true
			    yield
			ensure
			    Thread.current[:control_mutex_locked] = false
			end
		    end
		end
	    end
	end

	# Do not sleep or call Thread#pass if there is less that
	# SLEEP_MIN_TIME time left in the cycle
	SLEEP_MIN_TIME = 0.01

	# If true, abort if an unhandled exception is found
	attr_accessor :abort_on_exception
	# If true, abort if an application exception is found
	attr_accessor :abort_on_application_exception
	# If true, abort if a framework exception is found
	attr_accessor :abort_on_framework_exception

	@event_processing	= []
	@structure_checks	= []
	class << self
	    # List of procs which are called at each event cycle
	    attr_reader :event_processing

	    # List of procs to be called for task structure checking
	    #
	    # The blocks return a set of exceptions or nil. The exception
	    # *must* respond to #task or #generator to know from which task the
	    # problem comes.
	    attr_reader :structure_checks
	end

	# The plan being executed
	attr_reader :plan
	# A set of planners declared in this application
	attr_reader :planners

	def initialize
	    super
	    @quit        = 0
	    @cycle_index = 0
	    @planners    = []
	    @last_stop_count = 0
	    @plan        = Plan.new
	end

	# Disable event propagation
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
	# Enable event propagation
	def enable_propagation; EventGenerator.enable_propagation end
	# Check if event propagation is enabled or not
	def propagate?; EventGenerator.propagate? end

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

	# Abort the control loop because of +exceptions+
	def reraise(exceptions)
	    raise Aborting.new(exceptions)
	end

	# Process the pending events. The time at each event loop step
	# is saved into +timings+.
	def process_events(timings = {}, do_gc = false)
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
		tasks ||= [*e.task]
		[*tasks].each do |parent|
		    new_tasks = parent.reverse_generated_subgraph(TaskStructure::Hierarchy)
		    Control.fatal_exception(e, new_tasks)
		    kill_tasks.merge(new_tasks)
		end
		kill_tasks
	    end

	    plan.garbage_collect(kill_tasks)
	    timings[:end] = timings[:garbage_collect] = Time.now

	    if do_gc
		GC.force
		timings[:end] = timings[:ruby_gc] = Time.now
	    end

	    application_errors = Thread.current[:application_exceptions]
	    Thread.current[:application_exceptions] = nil
	    application_errors.each do |(event, origin), error|
		Roby.application_error(event, origin, error)
	    end

	    if abort_on_exception && !quitting? && !fatal_errors.empty?
		reraise(fatal_errors.map { |e, _| e })
	    end
	    
	    timings

	ensure
	    Thread.current[:application_exceptions] = nil
	end

	class << self
	    # A list of blocks to be called at the beginning of the next event loop
	    attribute(:process_once) { Queue.new }
	    # Calls all pending procs in +process_once+
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
		process_every.map! do |block, last_call, duration|
		    if !last_call || (now - last_call) > duration
			Propagation.gather_exceptions { block.call }
			last_call = now
		    end
		    [block, last_call, duration]
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
	
	    if options[:detach]
		self.thread = Thread.new { run(options.merge(:detach => false, :drb => nil)) }
		return
	    end
	    self.thread = Thread.current
	    self.thread.priority = 10

	    @quit = 0
	    yield if block_given?

	    cycle_length = options[:cycle]
	    if control_gc = options[:control_gc]
		already_disabled_gc = GC.disable
		GC.force
	    end
	    if log = options[:log]
		log << Marshal.dump(cycle_length)
	    end

	    event_loop(log, cycle_length, control_gc)

	ensure
	    if Thread.current == self.thread
		# reset the options only if we are in the control thread
		@thread = nil
		GC.enable if control_gc && !already_disabled_gc
		Control.finalizers.each { |blk| blk.call }
	    end
	end

	attr_reader :last_stop_count
	def clear
	    Control.synchronize do
		plan.keepalive.dup.each { |t| plan.auto(t) }
		plan.force_gc.merge( plan.missions )
	    end

	    remaining = plan.known_tasks.find_all { |t| Plan.can_gc?(t) }

	    if remaining.empty?
		# Done cleaning the tasks, clear the remains
		plan.transactions.each do |trsc|
		    trsc.discard_transaction
		end
		plan.clear
		return
	    end

	    if last_stop_count != remaining.size
		if last_stop_count == 0
		    Roby.info "control quitting. Waiting for #{remaining.size} tasks to finish:\n  #{remaining.join("\n  ")}"
		else
		    Roby.info "waiting for #{remaining.size} tasks to finish:\n  #{remaining.join("\n  ")}"
		end
		@last_stop_count = remaining.size
	    end
	    remaining
	end

	def event_loop(log, cycle, control_gc)
	    timings = {}
	    timings[:start] = Time.now

	    last_stop_count = 0

	    loop do
		begin
		    if quitting?
			return if forced_exit? || !clear
		    end

		    while Time.now > timings[:start] + cycle
			timings[:start] += cycle
			@cycle_index += 1
		    end
		    timings = Control.synchronize { process_events(timings, control_gc) }

		rescue Exception => e
		    unless quitting?
			Roby.warn "Control quitting because of unhandled exception"
			Roby.warn e.full_message
			quit
		    end
		end
		    
		timings[:pass] = timings[:sleep] = timings[:expected_sleep] = timings[:end]
		cycle_duration = timings[:end] - timings[:start]
		if cycle - cycle_duration > SLEEP_MIN_TIME
		    cycle_end(timings)
		    Thread.pass
		    timings[:pass] = Time.now

		    # Take the time we passed in other threads into account
		    sleep_time = cycle - (Time.now - timings[:start])
		    if sleep_time > 0
			timings[:expected_sleep] = Time.now + sleep_time
			sleep(sleep_time) 
			timings[:sleep] = Time.now
		    end
		end

		log << Marshal.dump(timings) if log
		timings[:start] += cycle
		@cycle_index += 1
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
