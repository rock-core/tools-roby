require 'tempfile'
require 'fileutils'

class Object
    def dot_id
        id = object_id
        id = if id < 0
                 (0xFFFFFFFFFFFFFFFF + id).to_s
             else
                 id.to_s
             end
        "object_#{id}"
    end
end

module Roby
    module GUI
        module GraphvizPlan
            attr_accessor :layout_level
            def all_events(display)
                known_tasks.inject(free_events.dup) do |events, task|
                    if display.displayed?(task)
                        events.merge(task.events.values.to_set)
                    else
                        events
                    end
                end
            end

            def to_dot(display, io, level)
                @layout_level = level
                io << "subgraph cluster_#{dot_id} {\n"
                (known_tasks | finalized_tasks | free_events | finalized_events).
                    each do |obj|
                        obj.to_dot(display, io) if display.displayed?(obj)
                    end

                io << "};\n"

                transactions.each do |trsc|
                    trsc.to_dot(display, io, level + 1)
                end

                relations_to_dot(display, io, each_task_relation_graph, known_tasks)
            end

            def each_edge(graph, display, objects)
                objects.each do |from|
                    next unless display.displayed?(from)
                    unless display[from]
                        DRoby::Logfile.warn "no display item for #{from} in #each_displayed_relation"
                        next
                    end

                    graph.each_out_neighbour(from) do |to|
                        next unless display.displayed?(to)
                        unless display[to]
                            DRoby::Logfile.warn "no display item for child in #{from} <#{rel}> #{to} in #each_displayed_relation"
                            next
                        end

                        yield(graph, from, to)
                    end
                end
            end

            def each_layout_relation(display, graphs, objects, &block)
                graphs.each do |g|
                    next unless display.layout_relation?(g.class)
                    each_edge(g, display, objects, &block)
                end
            end

            def each_displayed_relation(display, graphs, objects, &block)
                graphs.each do |g|
                    next unless display.relation_enabled?(g.class)
                    each_edge(g, display, objects, &block)
                end
            end

            def relations_to_dot(display, io, graphs, objects)
                each_layout_relation(display, graphs, objects) do |graph, from, to|
                    from_id, to_id = from.dot_id, to.dot_id
                    if from_id && to_id
                        io << "  #{from_id} -> #{to_id}\n"
                    else
                        DRoby::Logfile.warn "ignoring #{from}(#{from.object_id} #{from_id}) -> #{to}(#{to.object_id} #{to_id}) in #{graph.class} in #{caller(1).join("\n  ")}"
                    end
                end
            end

            def layout_relations(positions, display, graphs, objects)
                each_displayed_relation(display, graphs, objects) do |graph, from, to|
                    display.task_relation(from, to, graph.class, graph.edge_info(from, to))
                end
            end

            # The distance from the root plan
            attr_reader :depth

            # Computes the plan depths and max_depth for this plan and all its
            # children. +depth+ is this plan depth
            #
            # Returns max_depth
            def compute_depth(depth)
                @depth = depth
                child_depth = transactions.
                    map { |trsc| trsc.compute_depth(depth + 1) }.
                    max
                child_depth || depth
            end
            
            def apply_layout(bounding_rects, positions, display, max_depth = nil)
                max_depth ||= compute_depth(0)

                if rect = bounding_rects[dot_id]
                    item = display[self]
                    item.z_value = PLAN_LAYER + depth - max_depth
                    item.rect = rect
                else
                    DRoby::Logfile.warn "no bounding rectangle for #{self} (#{dot_id})"
                end


                (known_tasks | finalized_tasks | free_events | finalized_events).
                    each do |obj|
                        next if !display.displayed?(obj)
                        obj.apply_layout(bounding_rects, positions, display)
                    end

                transactions.each do |trsc|
                    trsc.apply_layout(bounding_rects, positions, display, max_depth)
                end
                layout_relations(positions, display, each_task_relation_graph.to_a, known_tasks)
            end
        end

        module GraphvizPlanObject
            def dot_label(display); display_name(display) end

            # Adds the dot definition for this object in +io+
            def to_dot(display, io)
                return unless display.displayed?(self)
                graphics = display.graphics[self]
                bounding_rect = graphics.bounding_rect
                if graphics.respond_to?(:text)
                    bounding_rect |= graphics.text.bounding_rect
                end

                io << "  #{dot_id}[label=\"#{dot_label(display).split("\n").join('\n')}\",width=#{bounding_rect.width},height=#{bounding_rect.height},fixedsize=true];\n"
            end

            # Applys the layout in +positions+ to this particular object
            def apply_layout(bounding_rects, positions, display)
                return unless display.displayed?(self)
                if p = positions[dot_id]
                    raise "no graphics for #{self}" unless graphics_item = display[self]
                    graphics_item.pos = p
                elsif b = bounding_rects[dot_id]
                    raise "no graphics for #{self}" unless graphics_item = display[self]
                    graphics_item.rect = b
                else
                    STDERR.puts "WARN: #{self} has not been layouted (#{dot_id.inspect})"
                end
            end
        end
        
        module GraphvizTaskEventGenerator
            include GraphvizPlanObject
            def dot_label(display); symbol.to_s end
        end

        module GraphvizTask
            include GraphvizPlanObject
            def to_dot_events(display, io)
                return unless display.displayed?(self)
                io << "subgraph cluster_#{dot_id} {\n"
                graphics = display.graphics[self]
                text_bb = graphics.text.bounding_rect
                has_event = false
                each_event do |ev|
                    if display.displayed?(ev)
                        ev.to_dot(display, io)
                        has_event = true
                    end
                end
                task_height = if !has_event then DEFAULT_TASK_HEIGHT + text_bb.height
                              else text_bb.height
                              end

                io << "  #{dot_id}[width=#{[DEFAULT_TASK_WIDTH, text_bb.width].max},height=#{task_height},fixedsize=true];\n"
                io << "}\n"
            end

            def dot_label(display)
                event_names = each_event.find_all { |ev| display.displayed?(ev) }.
                    map { |ev| ev.dot_label(display) }.
                    join(" ")

                own = super
                if own.size > event_names.size then own
                else event_names
                end
            end

            def apply_layout(bounding_rects, positions, display)
                if !(task = positions[dot_id])
                    puts "No layout for #{self}"
                    return
                end
                each_event do |ev|
                    next if !display.displayed?(ev)
                    positions[ev.dot_id] += task
                end
                # Apply the layout on the events
                each_event do |ev|
                    ev.apply_layout(bounding_rects, positions, display)
                end
                # And recalculate the bounding box
                bounding_rect = Qt::RectF.new
                each_event.map do |ev|
                    next if !display.displayed?(ev)
                    graphics = display[ev]
                    bounding_rect |= graphics.map_rect_to_scene(graphics.bounding_rect)
                    bounding_rect |= graphics.text.map_rect_to_scene(graphics.text.bounding_rect)
                end
                if !graphics_item = display[self]
                    raise "no graphics for #{self}" unless graphics_item = display[self]
                end
                if bounding_rect.null? # no events, we need to take the bounding box from the fake task node
                    bounding_rect = Qt::RectF.new(
                        task.x - DEFAULT_TASK_WIDTH / 2,
                        task.y - DEFAULT_TASK_HEIGHT / 2, DEFAULT_TASK_WIDTH, DEFAULT_TASK_HEIGHT)
                else
                    bounding_rect.y -= 5
                end
                graphics_item.rect = bounding_rect

                text_pos = Qt::PointF.new(
                    bounding_rect.x + bounding_rect.width / 2 - graphics_item.text.bounding_rect.width / 2,
                    bounding_rect.y + bounding_rect.height)
                graphics_item.text.pos = text_pos
            end
        end

        Roby::Plan.include GraphvizPlan
        Roby::PlanObject.include GraphvizPlanObject
        Roby::TaskEventGenerator.include GraphvizTaskEventGenerator
        Roby::Task.include GraphvizTask
        Roby::Task::Proxying.include GraphvizTask

        # This class uses Graphviz (i.e. the "dot" tool) to compute a layout for
        # a given plan
        class PlanDotLayout
            # The set of IDs for the objects in the plan
            attribute(:object_ids) { Hash.new }

            attr_reader :dot_input

            # Add a string to the resulting Dot input file
            def <<(string); dot_input << string end

            FLOAT_VALUE = "\\d+(?:\\.\\d+)?(?:e[+-]\\d+)?"
            DOT_TO_QT_SCALE_FACTOR_X = 1.0 / 55
            DOT_TO_QT_SCALE_FACTOR_Y = 1.0 / 55

            def self.parse_dot_layout(dot_layout, options = Hash.new)
                options = Kernel.validate_options options,
                    scale_x: DOT_TO_QT_SCALE_FACTOR_X,
                    scale_y: DOT_TO_QT_SCALE_FACTOR_Y
                scale_x = options[:scale_x]
                scale_y = options[:scale_y]

                current_graph_id = nil
                bounding_rects = Hash.new
                object_pos     = Hash.new
                full_line = ""
                dot_layout.each do |line|
                    line.chomp!
                    full_line << line.strip
                    if line[-1] == ?\\ or line[-1] == ?,
                        full_line.chomp!
                        next
                    end

                    case full_line
                    when /(\w+).*\[.*pos="(#{FLOAT_VALUE}),(#{FLOAT_VALUE})"/
                        object_pos[$1] = Qt::PointF.new(Float($2) * scale_x, Float($3) * scale_y)
                    when /subgraph cluster_(\w+)/
                        current_graph_id = $1
                    when /bb="(#{FLOAT_VALUE}),(#{FLOAT_VALUE}),(#{FLOAT_VALUE}),(#{FLOAT_VALUE})"/
                        bb = [$1, $2, $3, $4].map { |c| Float(c) }
                        bb[0] *= scale_x
                        bb[2] *= scale_x
                        bb[1] *= scale_x
                        bb[3] *= scale_x
                        bounding_rects[current_graph_id] = Qt::RectF.new(bb[0], bb[1], bb[2] - bb[0], bb[3] - bb[1])
                    end
                    full_line = ""
                end

                graph_bb = bounding_rects.delete(nil)
                if !graph_bb
                    raise "Graphviz failed to generate a layout for this plan"
                end
                bounding_rects.each_value do |bb|
                    bb.x -= graph_bb.x
                    bb.y  = graph_bb.y - bb.y - bb.height
                end
                object_pos.each do |id, pos|
                    pos.x -= graph_bb.x
                    pos.y = graph_bb.y - pos.y
                end

                return bounding_rects, object_pos
            end

            def run_dot(options = Hash.new)
                options, parsing_options = Kernel.filter_options options,
                    graph_type: 'digraph', layout_method: display.layout_method

                @@index ||= 0
                @@index += 1

                # Dot input file
                @dot_input  = Tempfile.new("roby_dot")
                # Dot output file
                dot_output = Tempfile.new("roby_layout")

                dot_input << "#{options[:graph_type]} relations {\n"
                yield(dot_input)
                dot_input << "}\n"

                dot_input.flush

                # Make sure the GUI keeps being updated while dot is processing
                FileUtils.cp dot_input.path, "/tmp/dot-input-#{@@index}.dot"
                system("#{options[:layout_method]} #{dot_input.path} > #{dot_output.path}")
                FileUtils.cp dot_output.path, "/tmp/dot-output-#{@@index}.dot"

                # Load only task bounding boxes from dot, update arrows later
                lines = File.open(dot_output.path) { |io| io.readlines  }
                PlanDotLayout.parse_dot_layout(lines, parsing_options)
            end

            # Generates a layout internal for each task, allowing to place the
            # events according to the propagations
            def layout(display, plan, options = Hash.new)
                @display         = display
                options = Kernel.validate_options options,
                    scale_x: DOT_TO_QT_SCALE_FACTOR_X, scale_y: DOT_TO_QT_SCALE_FACTOR_Y

                # We first layout only the tasks separately. This allows to find
                # how to layout the events within the task, and know the overall
                # task sizes
                all_tasks = Set.new
                bounding_boxes, positions = run_dot(graph_type: 'graph', layout_method: 'fdp', scale_x: 1.0 / 100, scale_y: 1.0 / 100) do
                    display.plans.each do |p|
                        p_tasks = p.known_tasks | p.finalized_tasks
                        p_tasks.each do |task|
                            task.to_dot_events(display, self)
                        end
                        all_tasks.merge(p_tasks)
                        p.propagated_events.each do |_, sources, to, _|
                            sources.each do |from|
                                if from.respond_to?(:task) && to.respond_to?(:task) && from.task == to.task
                                    from_id, to_id = from.dot_id, to.dot_id
                                    if from_id && to_id
                                        self << "  #{from.dot_id} -- #{to.dot_id}\n"
                                    end
                                end
                            end
                        end
                    end
                end

                # Ignore graphviz-generated BBs, recompute from the event
                # positions and then make their positions relative
                event_positions = Hash.new
                all_tasks.each do |t|
                    next if !display.displayed?(t)
                    bb = Qt::RectF.new
                    if p = positions[t.dot_id]
                        bb |= Qt::RectF.new(p, p)
                    end
                    t.each_event do |ev|
                        next if !display.displayed?(ev)
                        p = positions[ev.dot_id]
                        bb |= Qt::RectF.new(p, p)
                    end
                    t.each_event do |ev|
                        next if !display.displayed?(ev)
                        event_positions[ev.dot_id] = positions[ev.dot_id] - bb.topLeft
                    end
                    graphics = display.graphics[t]
                    graphics.rect = Qt::RectF.new(0, 0, bb.width, bb.height)
                end
                
                @bounding_rects, @object_pos = run_dot(scale_x: 1.0 / 50, scale_y: 1.0 / 15) do
                    # Finally, generate the whole plan
                    plan.to_dot(display, self, 0)

                    # Take the signalling into account for the layout. At this stage,
                    # task events are represented by their tasks
                    display.plans.each do |p|
                        p.propagated_events.each do |_, sources, to, _|
                            to_id =
                                if to.respond_to?(:task) then to.task.dot_id
                                else to.dot_id
                                end

                            sources.each do |from|
                                from_id =
                                    if from.respond_to?(:task)
                                        from.task.dot_id
                                    else
                                        from.dot_id
                                    end

                                if from_id && to_id
                                    self << "  #{from.dot_id} -> #{to.dot_id}\n"
                                end
                            end
                        end
                    end
                end
                object_pos.merge!(event_positions)

                @plan            = plan
            end

            attr_reader :bounding_rects, :object_pos, :display, :plan
            def apply
                plan.apply_layout(bounding_rects, object_pos, display)
            end
        end
    end
end
