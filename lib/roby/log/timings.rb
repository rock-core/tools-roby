module Roby
    module Log
	class Timings
	    REF_TIMING = :start
	    ALL_TIMINGS = [ :real_start, :events, 
		:events_exceptions, :structure_check, :structure_check_exceptions, 
		:fatal_structure_errors, :garbage_collect, :application_errors, :end, 
		:expected_ruby_gc, :ruby_gc, :expected_sleep, :sleep ]

	    NUMERIC_FIELDS = [:cycle_index, :live_objects, :object_allocation, :log_queue_size]

	    ALL_FIELDS = ALL_TIMINGS | NUMERIC_FIELDS

	    attr_reader :logfile
	    def initialize(logfile)
		@logfile = logfile
		rewind
	    end
	    def rewind; logfile.rewind end

	    def each_cycle(cumulative = false)
		while !logfile.eof?
		    result  = []
		    data    = timings = Marshal.load(logfile).last.last
		    ref     = timings.delete(REF_TIMING)
		    result  << ref

		    unknown_timings = (timings.keys.to_set - ALL_FIELDS.to_set)
		    raise "invalid list of timings: unknown #{unknown_timings.to_a.join(", ")}" unless unknown_timings.empty?
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

		    yield(data.values_at(*NUMERIC_FIELDS), result)
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
		mean, stdev = nil
		count = 0

		mean_cycle  = 0
		stdev_cycle = 0

		# Compute mean value
		each_cycle(false) do |numeric, timings|
		    if !mean
			mean  = Array.new(numeric.size + timings.size, 0.0)
		    end

		    # Compute mean value
		    start = timings.shift + timings.first
		    if last_start
			mean_cycle += start - last_start
		    end
		    last_start = start 

		    (numeric + timings).each_with_index { |v, i| mean[i] += v if v }
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

		format = "%-28s %-10.2f %-10.2f"

		puts "\n" + "Per-cycle statistics".center(50)
		puts "%-28s %-10s %-10s" % ['', 'mean', 'stddev']
		puts format % ["cycle", mean_cycle * 1000, Math.sqrt(stdev_cycle / count) * 1000]
		NUMERIC_FIELDS.each_with_index do |name, i|
		    puts format % [name, mean[i], stdev[i]] unless name == :cycle_index
		end

		puts "\n" + "Broken down cycle timings".center(50)
		puts "%-28s %-10s %-10s" % ['', 'mean', 'stddev']
		(ALL_TIMINGS).each_with_index do |name, i|
		    i += NUMERIC_FIELDS.size
		    puts format % [name, mean[i] * 1000, stdev[i] * 1000]
		end
	    end

	    def display(cumulative)
		header = ([REF_TIMING] + ALL_TIMINGS + NUMERIC_FIELDS).enum_for(:each_with_index).
		    map { |n, i| "#{i + 1}_#{n}" }.
		    join("\t")

		puts header
		each_cycle(cumulative) do |numeric, results|
		    print "#{timeval_to_s(results.shift)} "
		    print results.join(", ")
		    print " "
		    puts numeric.join(" ")
		end
	    end
	end
    end
end
