require 'roby'
require 'thor'

module Roby
    module CLI
        class Log < Thor
            no_commands do
                def handle_file_argument(file = nil)
                    return file if file && File.file?(file)

                    # If the argument is not a file, we assume it is a robot name
                    # and that the user wants the current log file for this particular
                    # robot configuration
                    if file
                        app = Roby::Application.new
                        app.guess_app_dir
                        app.setup_robot_names_from_config_dir
                        if !app.robot_name?(file)
                            raise ArgumentError, "expected #{file} to either the path to a log file, or a robot name to get the last log file from this robot configuration"
                        end
                        app.robot(file)
                    end
                    app.log_current_file
                end
            end

            desc 'upgrade-format', 'upgrades an older Roby log file to the newest version'
            def upgrade_format(file)
                require 'roby/log/upgrade'
                Roby::Log::Upgrade.to_new_format(file)
            end

            desc 'rebuild-index', 'rebuilds the index of an existing log file'
            def rebuild_index(file = nil)
                file = handle_file_argument(file)
                require 'roby/droby/logfile/reader'
                Roby::DRoby::Logfile::Reader.open(file).
                   rebuild_index
            end

            desc 'timepoints', 'extract timepoint information from the log file'
            option :raw, desc: 'display the timpoints as they appear instead of formatting them per-thread and per-group',
                type: :boolean, default: false
            option :flamegraph, type: :string, desc: 'path to a HTML file that will display a flame graph'
            option :ctf, type: :boolean, desc: 'generate a CTF file suitable to be analyzed by e.g. Trace Compass'
            def timepoints(file = nil)
                file = handle_file_argument(file)

                require 'roby/droby/logfile/reader'
                require 'roby/droby/timepoints'
                require 'roby/droby/timepoints_ctf'
                require 'roby/cli/log/flamegraph_renderer'

                stream = Roby::DRoby::Logfile::Reader.open(file)

                if options[:raw]
                    current_context = Hash.new
                    while data = stream.load_one_cycle
                        data.each_slice(4) do |m, sec, usec, args|
                            thread_id, thread_name, timepoint_name = *args
                            path = (current_context[thread_id] ||= [thread_name])

                            if m == :timepoint
                                puts "#{Roby.format_time(Time.at(sec, usec))} #{path.join("/")}/#{timepoint_name}"
                            elsif m == :timepoint_group_start
                                puts "#{Roby.format_time(Time.at(sec, usec))} #{path.join("/")}/#{timepoint_name} {"
                                path.push timepoint_name
                            elsif m == :timepoint_group_end
                                path.pop
                                puts "#{Roby.format_time(Time.at(sec, usec))} #{path.join("/")}/#{timepoint_name} }"
                            end
                        end
                    end
                    return
                end


                analyzer = Roby::DRoby::Timepoints::Analysis.new
                if options[:ctf]
                    analyzer = Roby::DRoby::Timepoints::CTF.new
                else
                    analyzer = Roby::DRoby::Timepoints::Analysis.new
                end
                while data = stream.load_one_cycle
                    data.each_slice(4) do |m, sec, usec, args|
                        if m == :timepoint
                            analyzer.add Time.at(sec, usec), *args
                        elsif m == :timepoint_group_start
                            analyzer.group_start Time.at(sec, usec), *args
                        elsif m == :timepoint_group_end
                            analyzer.group_end Time.at(sec, usec), *args
                        end
                    end
                end

                if options[:ctf]
                    path = Pathname.new(file).expand_path.sub_ext('.ctf')
                    path.mkpath
                    puts "saving in #{path}"
                    analyzer.save(path)
                elsif options[:flamegraph]
                    graph = analyzer.flamegraph
                    graph = graph.map do |name, duration|
                        [name, (duration * 1000).round]
                    end
                    File.open(options[:flamegraph], 'w') do |io|
                        io.write FlamegraphRenderer.new(graph).graph_html
                    end
                else
                    puts analyzer.format
                end
                exit 0
            end

            desc 'stats', 'show general timing statistics'
            option :save, type: :string, desc: 'file to save the CSV data to'
            def stats(file = nil)
                file = handle_file_argument(file)

                require 'roby/droby/logfile/reader'
                stream = Roby::DRoby::Logfile::Reader.open(file)
                index = stream.index

                cycle_count = index.size

                if cycle_count == 0
                    puts "empty log file"
                    exit 0
                end

                timespan    = index.range
                puts "#{cycle_count} cycles between #{timespan.first.to_hms} and #{timespan.last.to_hms}"
                process_utime = index.inject(0) { |old, info| old + info[:utime] }
                process_stime = index.inject(0) { |old, info| old + info[:stime] }
                real_time = timespan.last - timespan.first
                ratio = (process_utime + process_stime) / real_time
                puts "Time: %.2fs user / %.2fs sys / %.2fs real (%i%% CPU use)" %
                    [process_utime, process_stime, real_time, ratio * 100]

                min, max = nil
                event_count = index.inject(0) do |total, cycle_info|
                    count = cycle_info[:event_count]
                    min = count if !min || min > count
                    max = count if !max || max < count
                    total + count
                end
                puts "#{event_count} log events, #{event_count / cycle_count} events/cycle (min: #{min}, max: #{max})"

                io = STDOUT
                if options[:save]
                    io = File.open(options[:save], 'w')
                end

                header = %w{0_actual_start 1_cycle_index 2_log_queue_size 3_plan_task_count 4_plan_event_count 5_utime 6_stime 7_dump_time 8_duration 9_total_allocated_objects 10_minor 11_major 12_live_object_count 13_oob_removed 14_gc_total_time}
                formatting = %w{%i %i %i %i %.3f %.3f %.3f %.3f %i %i %i %i %i %.3f}
                formatting = formatting.join(",")

                puts header.join(",")
                index.each do |info|
                    gc = info[:gc]
                    oob_gc = info[:pre_oob_gc] || gc
                    start_sec, start_usec = info[:start]
                    start = Time.at(start_sec, start_usec)

                    io.puts (start + info[:actual_start]).strftime("%H:%M:%S.%3N") + " " + formatting % [
                        *info.values_at(:cycle_index, :log_queue_size, :plan_task_count, :plan_event_count, :utime, :stime, :dump_time, :end),
                        gc[:total_allocated_objects],
                        gc[:minor_gc_count],
                        gc[:major_gc_count],
                        gc[:total_allocated_objects] - gc[:total_freed_objects],
                        gc[:total_freed_objects] - oob_gc[:total_freed_objects],
                        info[:gc_total_time] || 0]
                end

                exit(0)
            end

            desc 'decode', 'show the raw events from the logfile'
            option :replay, type: :string,
                desc: "replay the log stream into a plan, add =debug to display more debugging information. Mainly useful to debug issues with the plan rebuilder",
                default: 'normal'
            def decode(file = nil)
                file = handle_file_argument(file)

                require 'roby/droby/logfile/reader'
                require 'roby/droby/plan_rebuilder'

                stream = Roby::DRoby::Logfile::Reader.open(file)
                if replay = options[:replay]
                    replay_debug = (replay == 'debug')
                    rebuilder = Roby::DRoby::PlanRebuilder.new
                end

                while data = stream.load_one_cycle
                    data.each_slice(4) do |m, sec, usec, args|
                        header = "#{Time.at(sec, usec)} #{m} "
                        puts "#{header} #{args.map(&:to_s).join("  ")}"
                        header = " " * header.size
                        if rebuilder
                            begin
                                rebuilder.process_one_event(m, sec, usec, args)
                                if replay_debug
                                    if m == :merged_plan
                                        puts "Merged plan"
                                        plan = args[1]
                                        puts "  #{plan.tasks.size} tasks: #{plan.tasks.map { |id, _| id.to_s }.join(", ")}"
                                        puts "  #{plan.task_events.size} task events: #{plan.task_events.map { |id, _| id.to_s }.join(", ")}"
                                        puts "  #{plan.free_events.size} events: #{plan.free_events.map { |id, _| id.to_s }.join(", ")}"
                                    end
                                    pp rebuilder
                                end
                            rescue Roby::DRoby::UnknownSibling
                                # Add some more debugging information
                                pp rebuilder
                                raise
                            end
                        end
                    end
                    if rebuilder
                        rebuilder.clear_integrated
                    end
                end
            end

            desc 'repair', 'attempt to repair a broken log file'
            def repair(file)
                require 'roby/droby/logfile/reader'
                logfile = Roby::DRoby::Logfile::Reader.open(file)
                last_cycle = nil
                while !logfile.eof?
                    current_pos = logfile.tell
                    begin
                        last_cycle = logfile.load_one_cycle
                    rescue Roby::DRoby::Logfile::TruncatedFileError
                        stat = File.stat(file)
                        puts "last chunk(s) in the file seem to have only been partially written."
                        puts "truncating at #{current_pos} out of #{stat.size} (removing #{stat.size - current_pos} bytes)"
                        if last_cycle
                            info  = last_cycle.last.last
                            end_time = Time.at(*info[:start]) + info[:end]
                            puts "the repaired file ends at #{end_time}"
                        else
                            puts "there are no valid cycles in the truncated file"
                        end
                        FileUtils.cp file, "#{file}.broken"
                        puts "the original has been saved as '#{file}.broken'"
                        File.open(file, 'a+') do |io|
                            io.truncate(current_pos)
                        end
                        break
                    end
                end
            ensure logfile.close
            end

            desc 'current', 'full path to the current log file'
            option :dir, aliases: 'd', type: :boolean
            def current(robot_name = nil)
                Roby.app.require_app_dir
                if robot_name
                    Roby.app.setup_robot_names_from_config_dir
                    Roby.app.robot(robot_name)
                end
                if options[:dir]
                    puts Roby.app.log_current_dir
                else
                    puts Roby.app.log_current_file
                end
            end

            desc 'display', "start roby-display to visualize the log file's contents"
            def display(file = nil)
                file = handle_file_argument(file)
                require 'roby/cli/display'
                Display.new.file(file)
            end
        end
    end
end
