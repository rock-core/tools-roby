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
	def full_message; message end
	def backtrace; [] end
    end

    class Pool < Queue
	def initialize(klass)
	    @klass = klass
	end

	def pop
	    unless value = pop(true) rescue nil
		return @klass.new
	    end
	    value
	end
    end

    @mutexes = Pool.new(Mutex)
    @condition_variables = Pool.new(ConditionVariable)
    class << self
	# Returns the only one Control object
	attr_reader :control
	# Returns the executed plan. This is equivalent to
	#   Roby.control.plan
	attr_reader :plan

	def every(duration, &block)
	    Control.every(duration, &block)
	end
	def each_cycle(&block)
	    Control.each_cycle(&block)
	end

	# Returns the control thread or, if control is not in a separate
	# thread, Thread.main
	def control_thread
	    Control.instance.thread || Thread.main
	end

	# True if the current thread is the control thread
	#
	# See #outside_control? for a discussion of the use of #inside_control?
	# and #outside_control? when testing the threading context
	def inside_control?
	    t = Control.instance.thread
	    !t || t == Thread.current
	end

	# True if the current thread is not control thread, or if
	# there is not control thread. When you check the current
	# thread context, always use a negated form. Do not do
	#
	#   if Roby.inside_control?
	#     ERROR
	#   end
	#
	# Do instead
	#
	#   if !Roby.outside_control?
	#     ERROR
	#   end
	#
	# Since the first form will fail if there is no control thread, while
	# the second form will work. Use the first form only if you require
	# that there actually IS a control thread.
	def outside_control?
	    t = Control.instance.thread
	    !t || t != Thread.current
	end

	# A pool of mutexes (as a Queue)
	attr_reader :mutexes
	# A pool of condition variables (as a Queue)
	attr_reader :condition_variables

	# call-seq:
	#   condition_variable => cv
	#   condition_variable(true) => cv, mutex
	#   condition_variable { |cv| ... } => value returned by the block
	#   condition_variable(true) { |cv, mutex| ... } => value returned by the block
	#
	# Get a condition variable object from the Roby.condition_variables
	# pool and, if mutex is not true, a Mutex object
	#
	# If a block is given, the two objects are yield and returned into the
	# pool after the block has returned. In that case, the method returns
	# the value returned by the block
	def condition_variable(mutex = false)
	    cv = condition_variables.pop

	    if block_given?
		begin
		    if mutex
			mt = mutexes.pop
			yield(cv, mt)
		    else
			yield(cv)
		    end

		ensure
		    return_condition_variable(cv, mt)
		end
	    else
		if mutex
		    return cv, mutexes.pop
		else
		    return cv
		end
	    end
	end

	# Execute the given block inside the control thread, and returns when
	# it has finished. The return value is the value returned by the block
	def execute
	    if Roby.inside_control?
		return yield
	    end

	    cv = condition_variable

	    return_value = nil
	    Roby::Control.synchronize do
		caller_thread = Thread.current

		Roby::Control.once do
		    begin
			return_value = yield
		    rescue Exception => e
			caller_thread.raise e
		    end
		    cv.broadcast
		end
		cv.wait(Roby::Control.mutex)
	    end
	    return_value

	ensure
	    return_condition_variable(cv)
	end

	# Execute the given block in the control thread, but don't wait for its
	# completion like Roby.execute does
	def once
	    Roby::Control.once { yield }
	end

	# Stops the current thread until the given even is emitted
	def wait_until(ev)
	    if Roby.inside_control?
		raise "cannot use #wait_until in control thread"
	    end

	    condition_variable(true) do |cv, mt|
		caller_thread = Thread.current

		mt.synchronize do
		    Roby.once do
			ev.if_unreachable(true) do
			    caller_thread.raise UnreachableEvent.new(ev)
			end
			ev.on do
			    mt.synchronize { cv.broadcast }
			end
			yield
		    end
		    cv.wait(mt)
		end
	    end
	end

	# Returns a ConditionVariable and optionally a Mutex into the
	# Roby.condition_variables and Roby.mutexes pools
	def return_condition_variable(cv, mutex = nil)
	    condition_variables.push cv
	    if mutex
		mutexes.push mutex
	    end
	    nil
	end
    end

    # This singleton class is the central object: it handles the event loop,
    # event propagation and exception propagation.
    class Control
	include Singleton

	@mutex = Mutex.new
	class << self
	    attr_reader :mutex

	    # Implements a recursive behaviour on Control.mutex
	    def synchronize
		if Thread.current[:control_mutex_locked]
		    yield
		else
		    begin
			mutex.lock
			Thread.current[:control_mutex_locked] = true
			yield
		    ensure
			Thread.current[:control_mutex_locked] = false
			mutex.unlock
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
	    Roby.instance_variable_set(:@plan, @plan)
	    plan.extend Roby::Propagation::ExecutablePlanChanged
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
	    for prc in Control.structure_checks
		new_exceptions = nil
		Propagation.gather_exceptions(prc, 'structure check') { new_exceptions = prc.call(plan) }
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
	    if exceptions.size == 1
		e = exceptions.first
		if e.kind_of?(ExecutionException)
		    e = e.exception
		end
		raise e, e.message, Roby.filter_backtrace(e.backtrace || [])
	    else
		raise Aborting.new(exceptions)
	    end
	end

	# Process the pending events. The time at each event loop step
	# is saved into +stats+.
	def process_events(stats = {})
	    Thread.current[:application_exceptions] = []

	    stats[:real_start] = Time.now

	    # Gather new events and propagate them
	    events_errors = Propagation.propagate_events(Control.event_processing)
	    stats[:events] = Time.now

	    # HACK: events_errors is sometime nil here. It shouldn't
	    events_errors ||= []

	    # Propagate exceptions that came from event propagation
	    events_errors = Propagation.propagate_exceptions(events_errors)
	    stats[:events_exceptions] = Time.now

	    # Generate exceptions from task structure
	    structure_errors = structure_checking
	    stats[:structure_check] = Time.now
	    structure_errors = Propagation.propagate_exceptions(structure_errors)
	    stats[:structure_check_exceptions] = Time.now

	    # Get the remaining problems in the plan structure, and act on it
	    fatal_structure_errors = structure_checking
	    fatal_errors = fatal_structure_errors.to_a + events_errors
	    stats[:fatal_structure_errors] = Time.now
	    # Get the list of tasks we should kill because of fatal_errors
	    kill_tasks = fatal_errors.inject(ValueSet.new) do |kill_tasks, (error, tasks)|
		tasks ||= [*error.task]
		for parent in [*tasks]
		    new_tasks = parent.reverse_generated_subgraph(TaskStructure::Hierarchy)
		    Control.fatal_exception(error, new_tasks)
		    kill_tasks.merge(new_tasks)
		end
		kill_tasks
	    end

	    plan.garbage_collect(kill_tasks)
	    stats[:garbage_collect] = Time.now

	    application_errors = Thread.current[:application_exceptions]
	    Thread.current[:application_exceptions] = nil
	    for (event, origin), error in application_errors
		Roby.application_error(event, origin, error)
	    end
	    stats[:end] = stats[:application_errors] = Time.now

	    if abort_on_exception && !quitting? && !fatal_errors.empty?
		reraise(fatal_errors.map { |e, _| e })
	    end

	    stats

	ensure
	    Thread.current[:application_exceptions] = nil
	end

	# Blocks until at least once execution cycle has been done
	def wait_one_cycle
	    current_cycle = Roby.execute { Roby.control.cycle_index }
	    while current_cycle == Roby.execute { Roby.control.cycle_index }
		sleep(0.5)
	    end
	end

	@process_once = Queue.new
	@at_cycle_end_handlers = Array.new
	@process_every = Array.new
	class << self
	    # A list of blocks to be called at the beginning of the next event loop
	    attr_reader :process_once
	    # Calls all pending procs in +process_once+
	    def call_once # :nodoc:
		while (p = process_once.pop(true) rescue nil)
		    Propagation.gather_exceptions(p, 'call once processing') { p.call }
		end
	    end
	    Control.event_processing << Control.method(:call_once)

	    # Call block once before event processing
	    def once(&block); process_once.push block end
	    # Call +block+ at each cycle
	    def each_cycle(&block); Control.event_processing << block end

	    # A set of blocks that are called at each cycle end
	    attr_reader :at_cycle_end_handlers

	    # Call +block+ at the end of the execution cycle	
	    def at_cycle_end(&block)
		Control.at_cycle_end_handlers << block
	    end

	    # A set of blocks which are called every cycle
	    attr_reader :process_every

	    # Call +block+ every +duration+ seconds. Note that +duration+ is
	    # round up to the cycle size (time between calls is *at least* duration)
	    def every(duration, &block)
		Control.once do
		    block.call
		    process_every << [block, Roby.control.cycle_start, duration]
		end
		block.object_id
	    end

	    def remove_periodic_handler(id)
		Roby.execute do
		    process_every.delete_if { |spec| spec[0].object_id == id }
		end
	    end

	    def call_every # :nodoc:
		now        = Roby.control.cycle_start
		length     = Roby.control.cycle_length
		process_every.map! do |block, last_call, duration|
		    Propagation.gather_exceptions(block, "call every(#{duration})") do
			# Check if the nearest timepoint is the beginning of
			# this cycle or of the next cycle
			if !last_call || (duration - (now - last_call)) < length / 2
			    block.call
			    last_call = now
			end
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

	# The starting point of this cycle
	attr_reader :cycle_start

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

	    event_loop(cycle_length, control_gc)

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
		plan.missions.dup.each { |t| plan.discard(t) }
		plan.keepalive.dup.each { |t| plan.auto(t) }
		plan.force_gc.merge( plan.known_tasks )

		remaining = plan.known_tasks.find_all { |t| Plan.can_gc?(t) }

		if remaining.empty?
		    # Have to call #garbage_collect one more to make
		    # sure that unneeded events are removed as well
		    plan.garbage_collect
		    # Done cleaning the tasks, clear the remains
		    plan.transactions.each do |trsc|
			trsc.discard_transaction if trsc.self_owned?
		    end
		    plan.clear
		    return
		end

		remaining = remaining.find_all do |task|
		    !task.finished?
		end

		if last_stop_count != remaining.size
		    if last_stop_count == 0
			Roby.info "control quitting. Waiting for #{remaining.size} tasks to finish (#{plan.size} tasks still in plan):\n  #{remaining.join("\n  ")}"
		    else
			Roby.info "waiting for #{remaining.size} tasks to finish (#{plan.size} tasks still in plan):\n  #{remaining.join("\n  ")}"
		    end
		    @last_stop_count = remaining.size
		end
		remaining
	    end
	end

	# Object count on which we base ourselves to start the GC
	attr_reader :gc_last_cycle
	attr_reader :gc_last_count

	# If ObjectSpace.live_objects is available, we start the GC only if
	# there is more than this constant objects allocated more than
	# gc_base_count
	GC_OBJECT_THRESHOLD = 10000

	# If ObjectSpace.live_objects is not available, we start the GC only if
	# there is at least more than this count of cycles spent before the
	# last time we ran it. 	
	GC_CYCLE_THRESHOLD = 20

	# Statistics about the GC. It is used to compute a GC_run / object
	# count ratio and determine if we are likely to have enough time to run
	# the garbage collector
	attr_reader :gc_stats

	# If no statistics are available, consider that the GC needs at least
	# this much time to run
	GC_DEFAULT_TIME = 0.050

	# Always start the GC if the predicted time is more that this much time
	GC_MAX_TIME = 0.090

	def predicted_gc_runtime
	    if gc_stats && gc_stats[0] != 0
		ObjectSpace.live_objects * gc_stats[0] / gc_stats[1]
	    else
		GC_DEFAULT_TIME
	    end
	end

	def start_ruby_gc
	    if ObjectSpace.respond_to?(:live_objects)
		if !gc_last_count
		    @gc_last_count = ObjectSpace.live_objects
		    @gc_stats = [0, 0]
		elsif (ObjectSpace.live_objects - gc_last_count) > GC_OBJECT_THRESHOLD
		    before_count = ObjectSpace.live_objects
		    gc_stats[1] += ObjectSpace.live_objects
		    before = Time.now
		    GC.force
		    gc_stats[0] += Time.now - before
		    @gc_last_count = ObjectSpace.live_objects
		end
	    elsif !gc_last_cycle
		@gc_last_cycle = cycle_index
	    elsif (cycle_index - gc_last_cycle) > GC_CYCLE_THRESHOLD
		GC.force
		@gc_last_cycle = cycle_index
	    end
	end

	def event_loop(cycle, control_gc)
	    stats = {}
	    stats[:start] = Time.now

	    last_stop_count = 0

	    loop do
		begin
		    if quitting?
			thread.priority = 0
			begin
			    return if forced_exit? || !clear
			rescue Exception => e
			    Roby.warn "Control failed to clean up"
			    Roby.warn e.full_message
			    return
			end
		    end

		    if GC.respond_to?(:time)
			gc_time_at_start = GC.time
		    end

		    while Time.now > stats[:start] + cycle
			stats[:start] += cycle
			@cycle_index += 1
		    end
		    @cycle_start = stats[:start]
		    stats[:cycle_index] = @cycle_index
		    stats = Control.synchronize { process_events(stats) }
		    
		    stats[:expected_ruby_gc] = stats[:ruby_gc] = 
			stats[:sleep] = stats[:expected_sleep] = stats[:end]

		    cycle_duration = stats[:end] - stats[:start]
		    if ObjectSpace.respond_to?(:live_objects)
			live_objects = ObjectSpace.live_objects
			if stats[:live_objects]
			    stats[:object_allocation] = live_objects - stats[:live_objects]
			else
			    stats[:object_allocation] = 0
			end
			stats[:live_objects]      = live_objects
		    end

		    if cycle - cycle_duration > SLEEP_MIN_TIME
			# Take the time we passed for GC into account
			sleep_time = cycle - cycle_duration

			if control_gc 
			    gc_runtime = predicted_gc_runtime
			    if sleep_time > gc_runtime || gc_runtime > GC_MAX_TIME
				stats[:expected_ruby_gc] = Time.now + gc_runtime
				start_ruby_gc
			    end
			end
			stats[:expected_ruby_gc] ||= Time.now
			stats[:ruby_gc] = Time.now

			sleep_time = cycle - (Time.now - stats[:start])
			if sleep_time > 0
			    stats[:expected_sleep] = Time.now + sleep_time
			    sleep(sleep_time) 
			    stats[:sleep] = Time.now

			end
		    end

		    if gc_time_at_start && !control_gc 
			stats[:ruby_gc_duration] = GC.time - gc_time_at_start
		    end
		    if defined? Roby::Log
			stats[:log_queue_size] = Roby::Log.logged_events.size
		    end
		    stats[:plan_task_count] = Roby.plan.known_tasks.size
		    stats[:plan_event_count] = Roby.plan.free_events.size
		    cycle_end(stats)

		    stats[:start] += cycle
		    @cycle_index += 1

		rescue Exception => e
		    unless quitting?
			Roby.warn "Control quitting because of unhandled exception"
			Roby.warn e.full_message
		    end
		    quit
		end
	    end
	ensure
	    stats[:end] = Time.now
	    cycle_end(stats)
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
	def cycle_end(stats)
	    super if defined? super 

	    Control.at_cycle_end_handlers.each do |handler|
		Propagation.gather_exceptions(handler, "at cycle end") { handler.call }
	    end
	end

	# If the event thread has been started in its own thread, 
	# wait for it to terminate
	def join
	    thread.join if thread

	rescue Interrupt
	    Roby.logger.level = Logger::INFO
	    Roby.info "received interruption request"
	    quit
	    if @quit > 2
		thread.raise Interrupt, "interrupting control thread at user request"
	    end
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
	    "mission #{mission} failed with failed(#{mission.terminal_event.context})\n#{super}"
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

module Roby
    @control = Control.instance
end
