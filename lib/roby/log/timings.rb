module Roby
    module Log
	class Timings
	    REF_TIMING = :start
	    ALL_TIMINGS = [ :real_start, :events, 
		:structure_check, :exception_propagation,
		:exceptions_fatal, :garbage_collect, :application_errors, 
		:expected_ruby_gc, :ruby_gc, :droby, :expected_sleep, :sleep, :end ]
	
	    NUMERIC_FIELDS = [:cycle_index, :live_objects, :object_allocation, :log_queue_size, :ruby_gc_duration, 
		:plan_task_count, :plan_event_count]
	    DELTAS = [:cpu_time]
	    ALL_NUMERIC_FIELDS = NUMERIC_FIELDS + DELTAS

	    ALL_FIELDS = ALL_TIMINGS + ALL_NUMERIC_FIELDS + [:event_count, :pos]

	    attr_reader :logfile
	    attr_reader :ignored_timings
	    def initialize(logfile)
		@logfile = logfile
		@ignored_timings = Set.new
		rewind
	    end
	    def rewind; logfile.rewind end

	    def each_cycle(cumulative = false)
		last_deltas = Hash.new
		for data in logfile.index_data[1..-1]
		    result  = []
		    timings = data
		    ref     = timings.delete(REF_TIMING)
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
			timings.inject(ref) do |last, time| 
			    time ||= last
			    result << time - ref
			    time
			end
		    else
			timings.inject(ref) do |last, time| 
			    time ||= last
			    result << time - last
			    time
			end
		    end

		    numeric = data.values_at(*NUMERIC_FIELDS)
		    deltas = DELTAS.map do |name|
			value = if old_value = last_deltas[name]
				    data[name] - old_value
				else
				    0
				end
			last_deltas[name] = data[name]
			value
		    end

		    yield(numeric + deltas, result)
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
		rewind
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
