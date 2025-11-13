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

            def timegroup_display(m)
                @displayed_timegroups << m
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

            def dump(m, time, *args)
                display_event(m, time, args)
            end

            def dump_timepoint(m, time, *args)
                case m
                when :timepoint
                    display_event(args[-1], time) if display_timepoint?(m)
                when :timepoint_group_start
                    name = args[-1]
                    push_timepoint_group_start(name, time) if display_timegroup?(name)
                when :timepoint_group_end
                    name = args[-1]
                    display_timegroup(name, time) if display_timegroup?(name)
                end
            end

            def display_timepoint?(name)
                name = name.to_s
                @displayed_timepoints.any? { |m| m === name }
            end

            def display_timegroup?(name)
                name = name.to_s
                @displayed_timegroups.any? { |m| m === name }
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
                    @out.puts "time group %<name>s: cannot find start event"
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
