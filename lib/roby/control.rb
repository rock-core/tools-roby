require 'roby'
require 'utilrb/exception/full_message'

require 'drb'
require 'set'

module Roby
    class Pool < Queue
	def initialize(klass)
	    @klass = klass
            super()
	end

	def pop
	    value = super(true) rescue nil
	    value || @klass.new
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
		if !Roby.control.running?
		    raise "control thread not running"
		end

		caller_thread = Thread.current
		Control.waiting_threads << caller_thread

		Roby::Control.once do
		    begin
			return_value = yield
			cv.broadcast
		    rescue Exception => e
			caller_thread.raise e
		    end
                    Control.waiting_threads.delete(caller_thread)
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
	def wait_one_cycle
	    Roby.control.wait_one_cycle
	end

	# Stops the current thread until the given even is emitted
	def wait_until(ev)
	    if Roby.inside_control?
		raise ThreadMismatch, "cannot use #wait_until in control thread"
	    end

	    condition_variable(true) do |cv, mt|
		caller_thread = Thread.current

		mt.synchronize do
		    Roby::Control.once do
			ev.if_unreachable(true) do |reason|
			    caller_thread.raise UnreachableEvent.new(ev, reason)
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

	    def taken_mutex?; Thread.current[:control_mutex_locked] end

	    # Implements a recursive behaviour on Control.mutex
	    def synchronize
		if Thread.current[:control_mutex_locked]
		    yield
		else
		    mutex.lock
		    begin
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
	# this much time left in the cycle
	SLEEP_MIN_TIME = 0.01

	# The priority of the control thread
	THREAD_PRIORITY = 10

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
	    @thread      = nil
	    @cycle_index = 0
	    @cycle_start = Time.now
	    @cycle_length = 0
	    @planners    = []
	    @last_stop_count = 0
	    @plan        = Plan.new
	    Roby.instance_variable_set(:@plan, @plan)
	    plan.extend Roby::Propagation::ExecutablePlanChanged
	end

	# Perform the structure checking step by calling the procs registered
	# in Control::structure_checks. These procs are supposed to return a
	# collection of exception objects, or nil if no error has been found
	def structure_checking
	    # Do structure checking and gather the raised exceptions
	    exceptions = {}
	    for prc in Control.structure_checks
		begin
		    new_exceptions = prc.call(plan)
		rescue Exception => e
		    Propagation.add_framework_error(e, 'structure checking')
		end
		next unless new_exceptions

		[*new_exceptions].each do |e, tasks|
		    e = Propagation.to_execution_exception(e)
		    exceptions[e] = tasks
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

	    add_timepoint(stats, :real_start)

	    # Gather new events and propagate them
	    events_errors = Propagation.propagate_events(Control.event_processing)
	    add_timepoint(stats, :events)

	    # HACK: events_errors is sometime nil here. It shouldn't
	    events_errors ||= []

	    # Generate exceptions from task structure
	    structure_errors = structure_checking
	    add_timepoint(stats, :structure_check)

	    # Propagate the errors. Note that the plan repairs are taken into
	    # account in Propagation.propagate_exceptions drectly.  We keep
	    # event and structure errors separate since in the first case there
	    # is not two-stage handling (all errors that have not been handled
	    # are fatal), and in the second case we call #structure_checking
	    # again to get the remaining errors
	    events_errors    = Propagation.propagate_exceptions(events_errors)
	    Propagation.propagate_exceptions(structure_errors)
	    add_timepoint(stats, :exception_propagation)

	    # Get the remaining problems in the plan structure, and act on it
	    fatal_structure_errors = Propagation.remove_inhibited_exceptions(structure_checking)
	    fatal_errors = fatal_structure_errors.to_a + events_errors
	    kill_tasks = fatal_errors.inject(ValueSet.new) do |kill_tasks, (error, tasks)|
		tasks ||= [*error.task]
		for parent in [*tasks]
		    new_tasks = parent.reverse_generated_subgraph(TaskStructure::Hierarchy) - plan.force_gc
		    if !new_tasks.empty?
			Control.fatal_exception(error, new_tasks)
		    end
		    kill_tasks.merge(new_tasks)
		end
		kill_tasks
	    end
	    add_timepoint(stats, :exceptions_fatal)

	    plan.garbage_collect(kill_tasks)
	    add_timepoint(stats, :garbage_collect)

	    application_errors = Thread.current[:application_exceptions]
	    Thread.current[:application_exceptions] = nil
	    for error, origin in application_errors
		Propagation.add_framework_error(error, origin)
	    end
	    add_timepoint(stats, :application_errors)

	    if abort_on_exception && !quitting? && !fatal_errors.empty?
		reraise(fatal_errors.map { |e, _| e })
	    end

	ensure
	    Thread.current[:application_exceptions] = nil
	end

	# Blocks until at least once execution cycle has been done
	def wait_one_cycle
	    current_cycle = Roby.execute { Roby.control.cycle_index }
	    while current_cycle == Roby.execute { Roby.control.cycle_index }
		raise ControlQuitError if !Roby.control.running?
		sleep(Roby.control.cycle_length)
	    end
	end

	@process_once = Queue.new
	@at_cycle_end_handlers = Array.new
	@process_every = Array.new
	@waiting_threads = Array.new
	class << self
	    # A list of threads which are currently waitiing for the control thread
	    # (see for instance Roby.execute)
	    #
	    # Control#run will raise ControlQuitError on this threads if they
	    # are still waiting while the control is quitting
	    attr_reader :waiting_threads
	    # A list of blocks to be called at the beginning of the next event loop
	    attr_reader :process_once
	    # Calls all pending procs in +process_once+
	    def call_once # :nodoc:
		while !process_once.empty?
		    p = process_once.pop
		    begin
			p.call
		    rescue Exception => e
			Propagation.add_framework_error(e, "call once in #{p}")
		    end
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
		    begin
			# Check if the nearest timepoint is the beginning of
			# this cycle or of the next cycle
			if !last_call || (duration - (now - last_call)) < length / 2
			    block.call
			    last_call = now
			end
		    rescue Exception => e
			Propagation.add_framework_error(e, "#call_every, in #{block}")
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

	# The number of this cycle since the beginning
	attr_reader :cycle_index

	# Main event loop. Valid options are
	# cycle::   the cycle duration in seconds (default: 0.1)
	# drb:: address of the DRuby server if one should be started (default: nil)
	# detach::  if true, start in its own thread (default: false)
	def run(options = {})
	    if running?
		raise "there is already a control running in thread #{@thread}"
	    end

	    options = validate_options options, 
		:cycle => 0.1, :detach => false

	    @quit = 0
	    if !options[:detach]
		@thread = Thread.current
		@thread.priority = THREAD_PRIORITY
	    end

	    if options[:detach]
		# Start the control thread and wait for @thread to be set
		Roby.condition_variable(true) do |cv, mt|
		    mt.synchronize do
			Thread.new do
			    run(options.merge(:detach => false)) do
				mt.synchronize { cv.signal }
			    end
			end
			cv.wait(mt)
		    end
		end
		raise unless @thread
		return
	    end

	    yield if block_given?

	    @cycle_length = options[:cycle]
	    event_loop

	ensure
	    if Thread.current == self.thread
		Roby::Control.synchronize do
		    # reset the options only if we are in the control thread
		    @thread = nil
		    Control.waiting_threads.each do |th|
			th.raise ControlQuitError
		    end
		    Control.finalizers.each { |blk| blk.call rescue nil }
		    @quit = 0
		end
	    end
	end

	attr_reader :last_stop_count
	def clear
	    Control.synchronize do
		plan.missions.dup.each { |t| plan.discard(t) }
		plan.keepalive.dup.each { |t| plan.auto(t) }
		plan.force_gc.merge( plan.known_tasks )

		quaranteened_subplan = plan.useful_task_component(nil, ValueSet.new, plan.gc_quarantine.dup)
		remaining = plan.known_tasks - quaranteened_subplan

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

		if last_stop_count != remaining.size
		    if last_stop_count == 0
			Roby.info "control quitting. Waiting for #{remaining.size} tasks to finish (#{plan.size} tasks still in plan)"
			Roby.debug "  " + remaining.to_a.join("\n  ")
		    else
			Roby.info "waiting for #{remaining.size} tasks to finish (#{plan.size} tasks still in plan)"
			Roby.debug "  #{remaining.to_a.join("\n  ")}"
		    end
		    if plan.gc_quarantine.size != 0
			Roby.info "#{plan.gc_quarantine.size} tasks in quarantine"
		    end
		    @last_stop_count = remaining.size
		end
		remaining
	    end
	end

	attr_reader :remaining_cycle_time
	def add_timepoint(stats, name)
	    stats[:end] = stats[name] = Time.now - cycle_start
	    @remaining_cycle_time = cycle_length - stats[:end]
	end
	def add_expected_duration(stats, name, duration)
	    stats[name] = Time.now + duration - cycle_start
	end

	def event_loop
	    @last_stop_count = 0
	    @cycle_start  = Time.now
	    @cycle_index  = 0

	    gc_enable_has_argument = begin
					 GC.enable(true)
					 true
				     rescue; false
				     end
	    stats = Hash.new
	    if ObjectSpace.respond_to?(:live_objects)
		stats[:live_objects] = ObjectSpace.live_objects
	    end

	    GC.start
	    if gc_enable_has_argument
		already_disabled_gc = GC.disable
	    end
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

		    while Time.now > cycle_start + cycle_length
			@cycle_start += cycle_length
			@cycle_index += 1
		    end
		    stats[:start]       = [cycle_start.tv_sec, cycle_start.tv_usec]
		    stats[:cycle_index] = cycle_index
		    Control.synchronize { process_events(stats) }
		    
		    # Record the statistics about object allocation *before* running the Ruby
		    # GC. It is also updated at 
		    if ObjectSpace.respond_to?(:live_objects)
			live_objects_before_gc = ObjectSpace.live_objects
		    end

		    # If the ruby interpreter we run on offers a true/false argument to
		    # GC.enable, we disabled the GC and just run GC.enable(true) to make
		    # it run immediately if needed. Then, we re-disable it just after.
		    if gc_enable_has_argument && remaining_cycle_time > SLEEP_MIN_TIME
			GC.enable(true)
			GC.disable
		    end
		    add_timepoint(stats, :ruby_gc)

		    if ObjectSpace.respond_to?(:live_objects)
			live_objects_after_gc = ObjectSpace.live_objects
		    end
		    
		    # Sleep if there is enough time for it
		    if remaining_cycle_time > SLEEP_MIN_TIME
			add_expected_duration(stats, :sleep, remaining_cycle_time)
			sleep(remaining_cycle_time) 
		    end
		    add_timepoint(stats, :sleep)

		    # Add some statistics and call cycle_end
		    if defined? Roby::Log
			stats[:log_queue_size] = Roby::Log.logged_events.size
		    end
		    stats[:plan_task_count]  = plan.known_tasks.size
		    stats[:plan_event_count] = plan.free_events.size
		    process_time = Process.times
		    stats[:cpu_time] = (process_time.utime + process_time.stime) * 1000

		    if ObjectSpace.respond_to?(:live_objects)
			live_objects = ObjectSpace.live_objects
			stats[:object_allocation] = live_objects - stats[:live_objects] - (live_objects_after_gc - live_objects_before_gc)
			stats[:live_objects]      = live_objects
		    end

		    cycle_end(stats)

		    stats = Hash.new
		    stats[:live_objects] = live_objects
		    @cycle_start += cycle_length
		    @cycle_index += 1

		rescue Exception => e
		    Roby.warn "Control quitting because of unhandled exception"
		    Roby.warn e.full_message
		    quit
		end
	    end

	ensure
	    GC.enable if !already_disabled_gc

	    if !plan.known_tasks.empty?
		Roby.warn "the following tasks are still present in the plan:"
		plan.known_tasks.each do |t|
		    Roby.warn "  #{t}"
		end
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
	def cycle_end(stats)
	    super if defined? super 

	    Control.at_cycle_end_handlers.each do |handler|
		begin
		    handler.call
		rescue Exception => e
		    Propagation.add_framework_error(e, "during cycle end handler #{handler}")
		end
	    end
	end

	# If the event thread has been started in its own thread, 
	# wait for it to terminate
	def join
	    thread.join if thread

	rescue Interrupt
	    Roby::Control.synchronize do
		return unless thread

		Roby.logger.level = Logger::INFO
		Roby.warn "received interruption request"
		quit
		if @quit > 2
		    thread.raise Interrupt, "interrupting control thread at user request"
		end
	    end

	    retry
	end

	attr_reader :cycle_index

	# Hook called when a set of tasks is being killed because of an exception
	def self.fatal_exception(error, tasks)
	    super if defined? super
	    Roby.warn "#{error.exception.message}: killing\n  #{tasks.to_a.join("\n  ")}"
	    Roby.info error.exception.full_message
	end
	# Hook called when an exception +e+ has been handled by +task+
	def self.handled_exception(e, task); super if defined? super end
    end

    # Get all missions that have failed
    def self.check_failed_missions(plan)
	result = []
	for task in plan.missions
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
