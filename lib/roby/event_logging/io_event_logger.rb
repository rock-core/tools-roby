# frozen_string_literal: true

module Roby
    module EventLogging
        # A simple event logger that displays a textual representation of the events
        # on plain I/O (e.g. log file or stdout)
        class IOEventLogger
            def initialize(out: $stdout)
                @out = out

                @displayed_timepoints = Set.new
                @displayed_timegroups = Set.new
                @displayed_events = Set.new
                @timepoint_group_start = {}
            end

            def log_timepoints?
                true
            end

            # Configure the logger to display timepoints as they happen
            #
            # The method shows the time (with a ms resolution) and the name
            #
            # @param [#===] matcher an object against which the timepoint name will be
            #   tested. Statistics will be shown for groups with matching names.
            #   Generally a string or a regular expression.
            #
            # @see timegroup_display event_display
            def timepoint_display(name)
                @displayed_timepoints << name
            end

            # Configure the logger to display statistics information about time groups
            #
            # @param [#===] matcher an object against which the timegroup name will be
            #   tested. Statistics will be shown for groups with matching names.
            #   Generally a string or a regular expression.
            # @param [Integer] skip skip this many start/end cycles before starting to
            #   gather statistics. Meant to "pass" a warmup period.
            #
            # @see timepoint_display event_display
            def timegroup_display(matcher, skip: 0)
                @displayed_timegroups << TimepointGroupDisplay.new(
                    matcher: matcher, skip: skip, stats: {}
                )
            end

            # Configure the logger to display events as they happen
            #
            # @param [#===] matcher an object against which the event name will be
            #   tested, usually either a string or a regular expression
            #
            # @see timepoint_display timegroup_display
            def event_display(matcher)
                @displayed_events << matcher
            end

            TimepointGroupStats = Struct.new(
                :fifo, :ref, :total, :min_duration, :max_duration, :sample_count,
                :mean, :sum_squares, :last_duration,
                keyword_init: true
            ) do
                def update(duration)
                    self.total += duration
                    update_min_max(duration)
                    update_statistics(duration, sample_count + 1)
                    self.sample_count = sample_count + 1
                    self.last_duration = duration
                end

                def variance
                    sum_squares / sample_count
                end

                def update_min_max(duration)
                    self.min_duration = duration if min_duration > duration
                    self.max_duration = duration if max_duration < duration
                end

                def update_statistics(duration, new_count)
                    old_mean = mean
                    new_mean = old_mean + mean_delta(old_mean, duration, new_count)
                    self.sum_squares += sum_squares_delta(duration, old_mean, new_mean)
                    self.mean = new_mean
                end

                def mean_delta(old_mean, duration, new_count)
                    (duration - old_mean) / new_count
                end

                def sum_squares_delta(duration, old_mean, new_mean)
                    (duration - new_mean) * (duration - old_mean)
                end

                def to_s
                    ratio = total / (Time.now - ref)
                    sd = Math.sqrt(variance)
                    format(
                        "max=%<max>.3f min=%<min>.3f total=%<ratio>i%% " \
                        "mean=%<mean>.3f sd=%<sd>.3f",
                        max: max_duration, min: min_duration, ratio: (ratio * 100).round,
                        mean: mean, sd: sd
                    )
                end
            end

            TIMEPOINT_GROUP_FORMAT = "timegroup %<name>s: %<duration>.3f - %<stats>s"

            TimepointGroupDisplay = Struct.new(
                :matcher, :skip, :start_times, :stats, keyword_init: true
            ) do
                # Add a group start event
                #
                # The event is queued (hence "pushed") to properly handle recursive
                # calls
                def push(name, time)
                    if skip > 0
                        self.skip -= 1
                        return
                    end

                    unless (msg_stats = stats[name])
                        msg_stats = TimepointGroupStats.new(
                            fifo: [], ref: Time.now, total: 0,
                            min_duration: Float::INFINITY,
                            max_duration: 0, sample_count: 0,
                            mean: 0, sum_squares: 0
                        )
                        stats[name] = msg_stats
                    end

                    msg_stats.fifo.push(time)
                end

                # Add a group end event
                def update(name, time)
                    return unless (msg_stats = stats[name])
                    return unless (start_t = msg_stats.fifo.pop)

                    msg_stats.update(time - start_t)
                end

                # Return the statistics message for the given timepoint
                def message(name, _time)
                    return unless (msg_stats = stats[name])

                    format(
                        TIMEPOINT_GROUP_FORMAT,
                        name: name, duration: msg_stats.last_duration,
                        stats: msg_stats.to_s
                    )
                end
            end

            Event = Struct.new :name, :time, :args do
                def pretty_print(pp)
                    pp.text "#{Roby.format_time(time)} #{name}"
                    pp.nest(2) do
                        args.each do |obj|
                            pp.breakable
                            obj.pretty_print(pp)
                        end
                    end
                end
            end

            def display_event(name, time, args)
                @out.puts PP.pp(Event.new(name, time, args), +"")
            end

            def display_event?(name)
                name = name.to_s
                @displayed_events.any? { |matcher| matcher === name }
            end

            # Called whenever there is a non-timepoint event
            #
            # @param [Symbol] name
            # @param [Time] time
            # @param [Array] args the event arguments
            def dump(name, time, args)
                return unless display_event?(name)

                display_event(name, time, args)
            end

            # Called whenever there is a timepoint event
            #
            # @param [:timepoint,:timepoint_group_start,:timepoint_group_end] the
            #   timepoint type
            # @param [Time] time
            # @param [Array] args the timepoint arguments, dependent on the timepoint
            #   type
            def dump_timepoint(timepoint_event, time, args)
                timepoint_name = args[-1]
                case timepoint_event
                when :timepoint
                    if display_timepoint?(timepoint_name)
                        display_event(timepoint_name, time, [])
                    end
                when :timepoint_group_start
                    dump_timepoint_group_start(timepoint_name, time)
                when :timepoint_group_end
                    dump_timepoint_group_end(timepoint_name, time)
                end
            end

            # @api private
            #
            # Helper for {#dump_timepoint} to handle timepoint group start events
            def dump_timepoint_group_start(timepoint_name, time)
                if (dis = find_timegroup_display(timepoint_name))
                    dis.push(timepoint_name, time)
                end

                return unless dis || display_timepoint?(timepoint_name)

                display_event("#{timepoint_name}:group-start", time, [])
            end

            # @api private
            #
            # Helper for {#dump_timepoint} to handle timepoint group end events
            def dump_timepoint_group_end(timepoint_name, time)
                if (dis = find_timegroup_display(timepoint_name))
                    dis.update(timepoint_name, time)
                    @out.puts dis.message(timepoint_name, time)
                end

                return unless dis || display_timepoint?(timepoint_name)

                display_event("#{timepoint_name}:group-end", time, [])
            end

            # Tests whether the given timepoint name is selected for display
            def display_timepoint?(name)
                name = name.to_s
                @displayed_timepoints.any? { |m| m === name }
            end

            # Looks for the timegroup display structure for the given group name
            def find_timegroup_display(name)
                name = name.to_s
                @displayed_timegroups.find { |d| d.matcher === name }
            end

            def push_timepoint_group_start(name, time)
                (@timepoint_group_start[name] ||= []) << time
            end

            def pop_timepoint_group_start(name)
                return unless (fifo = @timepoint_group_start[name])

                time = fifo.pop
                @timepoint_group_start.delete(name) if fifo.empty?
                time
            end

            def display_timegroup(name, time)
                unless (tic = pop_timepoint_group_start(name))
                    @out.puts format(
                        "time group %<name>s: cannot find start event",
                        name: name
                    )
                    return
                end

                message = format(
                    "time group %<name>s: %<duration>.3f",
                    name: name, duration: time - tic
                )
                @out.puts message
            end

            def close; end

            def log_queue_size
                0
            end

            def dump_time
                0
            end

            def flush_cycle(name, *args)
                dump(name, *args)
            end
        end
    end
end
