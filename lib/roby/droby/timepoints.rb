require 'json'

module Roby
    module DRoby
        module Timepoints
            class Analysis
                attr_reader :root
                attr_reader :current_group

                def initialize
                    @root = @current_group = Root.new
                end

                def add(time, name)
                    current_group.add(time, name)
                end

                def group_start(time, name)
                    @current_group = current_group.group_start(time, name)
                end

                def group_end(time, name)
                    if current_group == root
                        raise ArgumentError, "called #group_end on the root group"
                    elsif name != current_group.name
                        raise ArgumentError, "mismatching name in #group_end"
                    end

                    @current_group = current_group.group
                    current_group.group_end(time)
                end

                def flamegraph
                    raw = root.flamegraph
                    folded = Hash.new(0)
                    raw.each_slice(2) do |path, value|
                        folded[path] += value
                    end
                    folded.to_a.sort
                end

                def format(indent: 0, base_time: root.start_time, absolute_times: true)
                    root.format(indent: indent, base_time: base_time, absolute_times: absolute_times).
                        join("\n")
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

                def start_time; time end
                def end_time; time end
            end

            class Aggregate
                attr_reader :current_time
                attr_reader :timepoints

                def initialize
                    @timepoints = Array.new
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
                    start_format = "%5.3f %5.3f       #{" " * indent}%s"
                    end_format   = "%5.3f %5.3f %5.3f #{" " * indent}%s"
                    line_format  = "%5.3f %5.3f       #{" " * indent}  %s"

                    result = Array.new
                    result << start_format % [start_time - base_time, start_time - last_time, "#{name}:start"]

                    last_time = timepoints.inject(last_time) do |last, tp|
                        if tp.respond_to?(:format)
                            result.concat(tp.format(last_time: last, indent: indent + 2, base_time: base_time, absolute_times: absolute_times))
                            tp.end_time
                        else
                            result << line_format % [tp.time - base_time, tp.time - last, tp.name]
                            tp.time
                        end
                    end

                    result << end_format   % [end_time - base_time, end_time - last_time, duration, "#{name}:end"]
                    result
                end
                
                def path
                    [name]
                end

                def flamegraph
                    result = Array.new
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

                def initialize
                    super

                    @name = 'root'
                    @level = 0
                end
            end

            class Group < Aggregate
                attr_reader :name
                attr_reader :level
                attr_reader :group

                attr_reader :start_time
                attr_reader :end_time

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

