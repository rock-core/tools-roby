require 'roby'
require 'thor'
module Roby
    module CLI
        class Log < Thor
            desc 'upgrade-format', 'upgrades an older Roby log file to the newest version'
            def upgrade_format(file)
                require 'roby/log/upgrade'
                Roby::Log::Upgrade.to_new_format(file)
            end

            desc 'rebuild-index', 'rebuilds the index of an existing log file'
            def rebuild_index(file)
                require 'roby/droby/logfile/reader'
                Roby::DRoby::Logfile::Reader.open(file).
                   rebuild_index
            end

            desc 'timepoints', 'extract timepoint information from the log file'
            option :flamegraph, type: :string, desc: 'path to a HTML file that will display a flame graph'
            def timepoints(file)
                require 'roby/droby/logfile/reader'
                require 'roby/droby/timepoints'
                require 'roby/cli/log/flamegraph_renderer'

                stream = Roby::DRoby::Logfile::Reader.open(file)
                analyzer = Roby::DRoby::Timepoints::Analysis.new
                while data = stream.load_one_cycle
                    data.each_slice(4) do |m, sec, usec, args|
                        if m == :timepoint
                            analyzer.add Time.at(sec, usec), args.first
                        elsif m == :timepoint_group_start
                            analyzer.group_start Time.at(sec, usec), args.first
                        elsif m == :timepoint_group_end
                            analyzer.group_end Time.at(sec, usec), args.first
                        end
                    end
                end

                if options[:flamegraph]
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
            def stats(file)
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

                io.puts "1_cycle_index,2_log_queue_size,3_plan_task_count,4_plan_event_count,5_utime,6_stime,7_dump_time,8_duration,9_min_gc,10_maj_gc,11_allocated"
                index.each do |info|
                    io.puts "%i,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%i,%i,%i" % [
                        *info.values_at(:cycle_index, :log_queue_size, :plan_task_count, :plan_event_count, :utime, :stime, :dump_time, :end),
                        *info[:gc].values_at(:minor_gc_count, :major_gc_count, :total_allocated_object)]
                end
                exit(0)
            end

            desc 'decode', 'show the raw events from the logfile'
            option :replay, type: :string,
                desc: "replay the log stream into a plan, add =debug to display more debugging information. Mainly useful to debug issues with the plan rebuilder",
                default: 'normal'
            def decode(file)
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
                                        puts "  #{plan.known_tasks.size} tasks: #{plan.known_tasks.map { |id, _| id.to_s }.join(", ")}"
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
                while !logfile.eof?
                    current_pos = logfile.tell
                    begin logfile.load_one_cycle
                    rescue Roby::DRoby::Logfile::TruncatedFileError
                        puts "last chunk(s) in the file seem to have only been partially written, truncating at #{current_pos}"
                        FileUtils.cp filename.first, "#{filename}.broken"
                        event_io.truncate(current_pos)
                        break
                    end
                end
            end
        end
    end
end

