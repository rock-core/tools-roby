require 'roby/support'
require 'pp'

require 'stringio'
require 'builder'

module Roby

    # Node
    #   x
    #   y
    #   width
    #   height


    class Task
        attr_accessor :display_group, :display_node
        def make_node(group)
            display_node = Roby::Display::Graph.node(group)
        end
        def display(view = nil, x = 0)
            if view
                group = Display::Graph.hierarchy(view.canvas, self)
                group.
                    translate( x + group.width / 2, 16 ).
                    visible = true
            else
                require 'Qt'
                require 'roby/display/rvg-qt'
                a = Qt::Application.new( ARGV )

                canvas = Qt::Canvas.new(512, 256)
                view   = Qt::CanvasView.new(canvas)
                a.setMainWidget( view )

                display(view, 256)

                view.show()
                canvas.update()
                a.exec()
            end
        end
    end

    module Display
        module Graph
            @options    = Hash.new
            class << self
                attribute :font_size => 12, :event_radius => 6, :event_names => false

                attr_writer :spacing, :height, :interline
                def margin; font_size / 4 end
                def event_height; event_radius * 2 + (event_names ? (margin + font_size) : 0) end
                def height; margin + font_size + margin * 2 + event_height + margin end
                def interline;  @interline || (font_size + height * 2) end
                def spacing;    @spacing || event_radius end
            end

            # Order events in the same task
            def self.events(group, events)
                events.enum_for(:each_with_index).collect do |ev, idx|
                    event_group = group.g do |event_group|
                        spot = event_group.circle(event_radius).
                            styles :stroke => 'black', :stroke_width => 2, :fill => 'white'
                        if ev.model.symbol == :start
                            spot.styles :stroke => '#00BB00'
                        else
                            spot.styles :stroke => '#BB0000'
                        end

                        if event_names
                            event_name = ev.model.symbol.to_s
                            event_group.
                                text(0, event_radius + margin + font_size, event_name).
                                styles :text_anchor => 'middle'
                            event_group.width = [ text_width(event_name), event_radius * 2 ].max
                        else
                            event_group.width = event_radius * 2
                        end
                    end

                    [ev, event_group]
                end
            end

            def self.text_width(text)
                text.size * font_size
            end

            # Builds a canvas group which displays the task itself
            def self.task(group, task)
                group.g do |node|
                    class << node; attr_accessor :task, :events, :height end
                    node.styles :stroke => 'black', :fill => 'white'

                    event_nodes = self.events(node, task.enum_for(:each_event, false).to_a)
                    node.events = event_nodes = Hash[*event_nodes.flatten]
                    event_width = event_nodes.values.
                        inject(-spacing) { |w, event_group| w + event_group.width + spacing }

                    task_name   = task.model.name.gsub(/Roby::(?:Genom::)/, '')
                    width       = [ event_width, text_width(task_name) ].max + 2*margin
                    
                    event_spacing = spacing + (width - event_width) / event_nodes.size

                    node.x = 0
                    node.y = 0
                    node.width  = width 
                    node.height = height
                    node.task   = task

                    node_rect = node.rect(width, height, -width/2, 0).
                        styles :stroke_width => 1
                    node.line(-width / 2, 2 * margin + font_size, width / 2, 2 * margin + font_size)
                    node.text(0, font_size + margin, task_name).
                        styles :text_anchor => 'middle', :font_size => font_size, :font_weight => 'lighter'

                    x = -width/2 + event_spacing / 2
                    event_nodes.each do |_, event_group|
                        event_group.
                            translate(x + event_group.width / 2, margin * 3 + font_size + event_radius).
                            z = node_rect.z + 1
                        x += event_group.width + event_spacing
                    end
                end
            end

            class ArrayNode < Array
                attr_reader :node
                attr_accessor :display_group
                def initialize(node)
                    super() { |h, k| h[k] = Array.new }
                    @node = node
                end
                def make_node(group)
                    Graph.task(group, node)
                end
            end

            # Builds a group which includes +root+ and its subtree
            def self.hierarchy(group, root, enum_with = :each_child)
                # It is a hierarchy *graph*, not a tree
                # We first build a tree and use #tree to draw it and
                # then create the rest of the links

                # Sort the nodes by level
                level_of = Hash.new
                level_of[root] = 0
                levels = [ { root => nil } ]

                root.enum_bfs(enum_with) do |child, parent|
                    level_of[child] ||= (level_of[parent] + 1)

                    idx = level_of[child]
                    levels[idx] ||= Hash.new { |h, k| h[k] = Array.new }
                    levels[idx][child] << parent
                end

                # Sort the childs by their first parent (no smart management 
                # of graph structures and/or time structure for now)
                levels.map! do |children|
                    children.sort_by { |child, parents| parents.first.object_id if parents }
                end

                group.g do |graph_group|
                    class << graph_group; attr_accessor :width end

                    # Build a hash-based tree for use with #tree, and display the tree
                    tree = Hash.new { |h, k| h[k] = ArrayNode.new(k) }
                    levels.each do |children|
                        children.each do |child, (parent, _)|
                            tree[parent] << tree[child]
                        end
                    end

                    self.tree(graph_group, tree[root], :each)

                    # Set x and y global coordinates
                    tree[root].enum_bfs(:each) do |child, parent|
                        child.display_group.x += parent.display_group.x
                        child.display_group.y =  parent.display_group.y + interline
                    end

                    # Add the missing graph links
                    levels.each_with_index do |children, index|
                        children.each do |child, (_, *parents)|
                            child.display_group = tree[child].display_group
                            next unless parents
                            parents.each do |p| 
                                p.display_group = tree[p].display_group
                                graph_group.line(child.display_group.x, child.display_group.y, 
                                                 p.display_group.x, p.display_group.y + height)
                            end
                        end
                    end

                    graph_group.width = root.display_group.width
                end
            end

            def self.tree(group, root, enum_with = :each_child)
                children = root.enum_for(enum_with).to_a
                if children.empty?
                    return root.display_group = root.make_node(group)
                end

                root.display_group = group.g do |parent_group|
                    class << parent_group; attr_accessor :x, :y, :width end
                    parent_group.x = 0
                    parent_group.y = 0

                    children_group = parent_group.g do |children_group|
                        children.map! { |child| tree(children_group, child, enum_with) }

                        # Compute the group width
                        line_width = children.inject(0) { |w, child| w + child.width } + spacing * (children.size - 1)
                        parent_group.width = line_width

                        x = -line_width / 2
                        children.each do |child|
                            child_x = (x + child.width / 2)

                            child.translate(child_x, 0)
                            child.x = child_x

                            x = x + child.width + spacing
                        end
                    end
                    # Move the children
                    children_group.translate(0, interline)

                    # Connect the parent to the children
                    children.each { |child| parent_group.line(child.x, interline, 0, height) }
                    # Build the parent node
                    root.make_node(parent_group)
                end
            end
        end
    end
end

unless $0 == __FILE__
    def profile(key); yield end
else
    @@profile_data = Hash.new(0)
    def profile(key) 
        before = Time.now
        yield
    ensure
        @@profile_data[key] += Time.now - before
    end
    def display_profile
        @@profile_data.each do |key, length|
            puts "#{key}: #{Integer(length * 1000)}"
        end
    end

    class EventMockup
        attr_reader :name
        Model = Struct.new :symbol
        def initialize(name, terminal = false); @name, @terminal = name, terminal end
        def terminal?; @terminal end
        def model; Model.new name.to_sym end
    end
    class TaskMockup
        attr_reader :name, :children
        attr_accessor :display_group
        def initialize(name)
            @name = name 
            @children = []
        end
        def bound_events 
            @bound_events ||= [ EventMockup.new(:start, false), EventMockup.new(:stop, true) ]
        end

        Model = Struct.new(:name)
        def model
            m = Model.new
            m.name = name
            m
        end

        def each_child(&iterator); @children.each(&iterator) end
        def each_event(only_bounded, &iterator); bound_events.each(&iterator) end

        def display(view)
            group = Graph.hierarchy(view.canvas, self)
            group.
                translate( group.width / 2, 16 ).
                visible = true
        end
    end

    def fill_canvas(view)
        root    = TaskMockup.new('root')
        left    = TaskMockup.new('left')
        right   = TaskMockup.new('right')
        root.children << left << right
        common  = TaskMockup.new 'common'
        left.children << common
        right.children << common

        include Roby::Display
        Graph.event_names = true
        root.display(view)
    end

    require 'Qt'
    require 'rvg-qt'
    include Qt
    a = Application.new( ARGV )
    canvas = Canvas.new(512, 256)
    canvas.background_fill = 'white'
    view   = CanvasView.new(canvas)
    a.setMainWidget( view )

    fill_canvas(view)

    view.show()
    canvas.update()
    view.update()
    a.exec()
end

