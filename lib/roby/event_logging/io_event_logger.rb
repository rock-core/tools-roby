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

            def timepoint_display(m)
                @displayed_timepoints << m
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
                :matcher, :start_times, :stats, keyword_init: true
            ) do
                def push(name, time)
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

                def update(name, time)
                    return unless (msg_stats = stats[name])
                    return unless (start_t = msg_stats.fifo.pop)

                    msg_stats.update(time - start_t)
                end

                def message(name, _time)
                    return unless (msg_stats = stats[name])

                    format(
                        TIMEPOINT_GROUP_FORMAT,
                        name: name, duration: msg_stats.last_duration,
                        stats: msg_stats.to_s
                    )
                end
            end

            def timegroup_display(m)
                @displayed_timegroups << TimepointGroupDisplay.new(
                    matcher: m, stats: {}
                )
            end

            def event_display(m)
                @displayed_events << m
            end

            Event = Struct.new :m, :time, :args do
                def pretty_print(pp)
                    pp.text "#{Roby.format_time(time)} #{m}"
                    pp.nest(2) do
                        args.each do |obj|
                            pp.breakable
                            obj.pretty_print(pp)
                        end
                    end
                end
            end

            def display_event(m, time, args)
                return unless display_event?(m)

                @out.puts PP.pp(Event.new(m, time, args), +"")
            end

            def display_event?(name)
                name = name.to_s
                @displayed_events.any? { |m| m === name }
            end

            def dump(m, time, args)
                display_event(m, time, args)
            end

            def dump_timepoint(m, time, args)
                case m
                when :timepoint
                    display_event(args[-1], time) if display_timepoint?(m)
                when :timepoint_group_start
                    name = args[-1]
                    if (dis = find_timegroup_display(name))
                        dis.push(name, time)
                    end
                when :timepoint_group_end
                    name = args[-1]
                    if (dis = find_timegroup_display(name))
                        dis.update(name, time)
                        @out.puts dis.message(name, time)
                    end
                end
            end

            def display_timepoint?(name)
                name = name.to_s
                @displayed_timepoints.any? { |m| m === name }
            end

            def find_timegroup_display(name)
                name = name.to_s
                @displayed_timegroups.find { |dis| dis.matcher === name }
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

            def flush_cycle(m, *args); end
        end
    end
end
