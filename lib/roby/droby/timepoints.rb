# frozen_string_literal: true

require "json"

module Roby
    module DRoby
        module Timepoints
            class Analysis
                attr_reader :roots
                attr_reader :thread_names
                attr_reader :current_groups

                def initialize
                    @thread_names = {}
                    @roots = roots = {}
                    @current_groups = Hash.new do |h, thread_id|
                        roots[thread_id] = h[thread_id] = Root.new(thread_id)
                    end
                end

                def add(time, thread_id, thread_name, name)
                    thread_names[thread_id] ||= thread_name
                    current_groups[thread_id].add(time, name)
                end

                def group_start(time, thread_id, thread_name, name)
                    thread_names[thread_id] ||= thread_name
                    @current_groups[thread_id] = current_groups[thread_id].group_start(time, name)
                end

                def group_end(time, thread_id, thread_name, name)
                    thread_names[thread_id] ||= thread_name
                    current_g = current_groups[thread_id]
                    if current_g == roots[thread_id]
                        raise ArgumentError, "called #group_end on the root group"
                    elsif name != current_g.name
                        raise ArgumentError, "mismatching name in #group_end"
                    end

                    current_g = @current_groups[thread_id] = current_g.group
                    current_g.group_end(time)
                end

                def flamegraph
                    raw = roots.each_value.map(&:flamegraph)
                    folded = Hash.new(0)
                    raw.each_slice(2) do |path, value|
                        folded[path] += value
                    end
                    folded.to_a.sort
                end

                def format(indent: 0, base_time: roots.each_value.map(&:start_time).min, absolute_times: true)
                    roots.each_value.map do |root|
                        root.format(indent: indent, base_time: base_time, absolute_times: absolute_times)
                            .join("\n")
                    end.join("\n")
                end
            end

            class Point
                attr_reader :group
                attr_reader :name
                attr_reader :time
                attr_reader :duration

                def initialize(time, name, duration, group)
                    @time = time
                    @name = name
                    @duration = duration
                    @group = group
                end

                def path
                    group.path + [name]
                end

                def flamegraph
                    [path, duration]
                end

                def start_time
                    time
                end

                def end_time
                    time
                end
            end

            class Aggregate
                attr_reader :current_time
                attr_reader :timepoints

                def initialize
                    @timepoints = []
                end

                def start_time
                    timepoints.first.start_time
                end

                def end_time
                    timepoints.last.end_time
                end

                def duration
                    end_time - start_time
                end

                def add(time, name)
                    timepoints << Point.new(time, name, time - (current_time || time), self)
                    @current_time = time
                end

                def group_start(time, name)
                    group = Group.new(time, name, self)
                    timepoints << group
                    group
                end

                def group_end(time)
                    timepoints.last.close(time)
                    @current_time = time
                end

                def format(indent: 0, last_time: start_time, base_time: start_time, absolute_times: true)
                    start_format = "%5.3f %5.3f       #{' ' * indent}%s"
                    end_format   = "%5.3f %5.3f %5.3f #{' ' * indent}%s"
                    line_format  = "%5.3f %5.3f       #{' ' * indent}  %s"

                    result = []
                    result << Kernel.format(start_format, start_time - base_time, start_time - last_time, "#{name}:start")

                    last_time = timepoints.inject(last_time) do |last, tp|
                        if tp.respond_to?(:format)
                            result.concat(tp.format(last_time: last, indent: indent + 2, base_time: base_time, absolute_times: absolute_times))
                            tp.end_time
                        else
                            result << Kernel.format(line_format, tp.time - base_time, tp.time - last, tp.name)
                            tp.time
                        end
                    end

                    result << Kernel.format(end_format, end_time - base_time, end_time - last_time, duration, "#{name}:end")
                    result
                end

                def path
                    [name]
                end

                def flamegraph
                    result = []
                    duration = timepoints.inject(0) do |d, tp|
                        result.concat(tp.flamegraph)
                        d + tp.duration
                    end
                    result << path << self.duration - duration
                    result
                end
            end

            class Root < Aggregate
                attr_reader :name
                attr_reader :level

                def initialize(name = "root")
                    super()

                    @name = name
                    @level = 0
                end
            end

            class Group < Aggregate
                attr_reader :name
                attr_reader :level
                attr_reader :group

                attr_reader :start_time

                def initialize(time, name, group)
                    super()

                    @name  = name
                    @group = group
                    @level = group.level + 1

                    @current_time = time
                    @start_time = time
                end

                def path
                    @path ||= (group.path + [name])
                end

                def end_time
                    current_time
                end

                def close(time)
                    @current_time = time
                end
            end
        end
    end
end
