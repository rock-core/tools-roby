require 'set'

module Roby
    module DRoby
        module Logfile
            class Timings
                REF_TIMING = :start
                ALL_TIMINGS = [ :real_start, :events, 
                    :structure_check, :exception_propagation,
                    :exceptions_fatal, :garbage_collect, 
                    :ruby_gc, :expected_sleep, :sleep, :end ]
            
                ALL_NUMERIC_FIELDS = [:cycle_index, :live_objects, :object_allocation, :heap_slots,
                    :log_queue_size, :plan_task_count, :plan_event_count, :cpu_time]

                ALL_FIELDS = ALL_TIMINGS + ALL_NUMERIC_FIELDS + [:event_count, :pos]

                attr_reader :index
                attr_reader :ignored_timings
                def initialize(index)
                    @index = index
                    @ignored_timings = Set.new
                end

                # Read the logfile index, extract statistic information from it and
                # yield them cycle-by-cycle. The format of +timings+ is the
                # following:
                #
                #   [start, real_start, events, 
                #       structure_check, exception_propagation,
                #       exceptions_fatal, garbage_collect,
                #       ruby_gc, expected_sleep, sleep, end]
                #
                # where +start+ is the target start time of the cycle as a Time
                # object. The rest of the values are floating-point values which
                # represent offset from +start+ if +cumulative+ is true or offset
                # from the previous one if +cumulative+ is false. Therefore, in the
                # latter case, the values represent the actual duration of each
                # phase in the execution engine.
                #
                # The phases are as follows:
                # real_start::
                #   the actual starting time. It allows to see the offset due (for
                #   instance) to the uncertainty in sleep
                # events::
                #   event propagation phase, including the propagation of dRoby
                #   events (events coming from remote hosts)
                # structure_check::
                #   first structure checking pass
                # exception_propagation::
                #   exception propagation phase
                # exceptions_fatal::
                #   second structure checking pass, and propagation of the fatal
                #   errors (i.e. killing the involved tasks)
                # garbage_collect::
                #   Roby's garbage collection pass
                # ruby_gc:: 
                #   if GC.enable accepts a true/false argument, Roby will
                #   explicitely allow the GC to run only at a specific point, and
                #   monitor its execution time. This is the result.  Note that Roby
                #   issues a warning at startup if it is not the case.
                # expected_sleep:: 
                #   how much time Roby wanted to sleep (i.e. how many milliseconds
                #   were given to the sleep() call)
                # sleep::
                #   how much time Roby actually slept
                # end::
                #   end of the cycle
                #
                # The second array that is yield, +numeric+, contains non-timing
                # statistics. Its format is:
                #
                #   [cycle_index, live_objects, object_allocation, log_queue_size,
                #       plan_task_count, plan_event_count, cpu_time]
                # 
                # where
                #
                # cycle_index::
                #   The index of this cycle. Note that some number can be missing: if one
                #   cycle takes more than two time its allocated period, then +cycle_index+ is
                #   updated to reflect the cycles that have been missed.
                # live_objects:: 
                #   The count of allocated objects at the end of the cycle. It is only valid
                #   on Ruby interpreters that have been patched to report this value
                #   efficiently.
                # object_allocation::
                #   How many objects have been allocated during this cycle. This is valid only
                #   if Ruby GC is controlled by Roby (see the description of +ruby_gc+ above).
                #   Otherwise, it will be invalid in cycles where the Ruby GC ran, as the
                #   statistics can't correct the objects freed by Ruby's GC.
                # log_queue_size::
                #   The logger runs in a thread separated from the execution engine, and a
                #   fixed-size queue is used to communicate between the threads. This value is
                #   the size of the queue at the end of the cycle (after sleep()). It is
                #   mainly used for debugging purposes: if this queue is almost full, then the
                #   execution engine thread will probably be interrupted to let the log thread
                #   empty the queue.
                # plan_task_count::
                #   The count of tasks in the plan at the end of the cycle.
                # plan_event_count::
                #   The count of free events in the plan at the end of the cycle.
                # cpu_time::
                #   The CPU time taken by the Roby controller for this cycle.
                def each_cycle(cumulative = false) # :yield:numeric, timings
                    last_deltas = Hash.new
                    for data in index[1..-1]
                        result  = []
                        timings = data.dup
                        ref     = Time.at(*timings.delete(REF_TIMING))
                        result  << ref

                        unknown_timings = (timings.keys.to_set - ALL_FIELDS.to_set - ignored_timings)
                        if !unknown_timings.empty?
                            STDERR.puts "ignoring the following timings: #{unknown_timings.to_a.join(", ")}"
                            @ignored_timings |= unknown_timings
                        end
                        timings = ALL_TIMINGS.map do |name|
                            timings[name]
                        end

                        if cumulative
                            timings.inject(0) do |last, time| 
                                time ||= last
                                result << time
                                time
                            end
                        else
                            timings.inject(0) do |last, time| 
                                time ||= last
                                result << time - last
                                time
                            end
                        end

                        numeric = data.values_at(*ALL_NUMERIC_FIELDS)
                        yield(numeric, result)
                    end

                rescue ArgumentError => e
                    if e.message =~ /marshal data too short/
                        STDERR.puts "File truncated"
                    else raise
                    end
                end

                def timeval_to_s(t)
                    '%02i:%02i:%02i.%03i' % [t.tv_sec / 3600, t.tv_sec % 3600 / 60, t.tv_sec % 60, t.tv_usec / 1000]
                end

                def stats
                    last_start = nil
                    mean, max, stdev = nil
                    count = 0

                    mean_cycle  = 0
                    stdev_cycle = 0
                    max_cycle   = nil

                    # Compute mean value
                    each_cycle(false) do |numeric, timings|
                        if !mean
                            mean  = Array.new(numeric.size + timings.size, 0.0)
                            max   = Array.new
                        end

                        # Compute mean value
                        start = timings.shift + timings.first
                        if last_start
                            cycle_length = start - last_start
                            if !max_cycle || max_cycle < cycle_length
                                max_cycle = cycle_length
                            end
                            mean_cycle += cycle_length
                        end
                        last_start = start 

                        (numeric + timings).each_with_index do |v, i| 
                            mean[i] += v if v
                            max[i] = v if v && (!max[i] || max[i] < v)
                        end
                        count += 1
                    end
                    mean.map! { |v| v / count }
                    mean_cycle /= count

                    last_start = nil
                    stdev = Array.new(mean.size, 0.0)
                    each_cycle(false) do |numeric, timings|
                        start = timings.shift + timings.first
                        if last_start
                            stdev_cycle += (start - last_start - mean_cycle)**2
                        end
                        last_start = start

                        (numeric + timings).each_with_index { |v, i| stdev[i] += (v - mean[i]) ** 2 if v }
                    end
                    stdev.map! { |v| Math.sqrt(v / count) if v }

                    format = "%-28s %-10.2f %-10.2f %-10.2f"

                    puts "\n" + "Per-cycle statistics".center(50)
                    puts "%-28s %-10s %-10s %-10s" % ['', 'mean', 'stddev', 'max']
                    puts format % ["cycle", mean_cycle * 1000, Math.sqrt(stdev_cycle / count) * 1000, max_cycle * 1000]
                    ALL_NUMERIC_FIELDS.each_with_index do |name, i|
                        puts format % [name, mean[i], stdev[i], (max[i] || 0)] unless name == :cycle_index
                    end

                    puts "\n" + "Broken down cycle timings".center(50)
                    puts "%-28s %-10s %-10s %-10s" % ['', 'mean', 'stddev', 'max']
                    (ALL_TIMINGS).each_with_index do |name, i|
                        i += ALL_NUMERIC_FIELDS.size
                        puts format % [name, mean[i] * 1000, stdev[i] * 1000, max[i] * 1000]
                    end
                end

                def display(cumulative)
                    header = ([REF_TIMING] + ALL_TIMINGS + ALL_NUMERIC_FIELDS).enum_for(:each_with_index).
                        map { |n, i| "#{i + 1}_#{n}" }.
                        join("\t")

                    puts header
                    each_cycle(cumulative) do |numeric, results|
                        print "#{timeval_to_s(results.shift)} "
                        print results.join(" ")
                        print " "
                        puts numeric.join(" ")
                    end
                end
            end
        end
    end
end
