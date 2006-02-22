require 'roby/support'
require 'pp'

module Roby
    class Task
        attr_accessor :display_group, :display_node
        def display(group)
            display_node = Roby::Display::Graph.node(group)
        end
    end

    module Display
        module Graph
            @options    = Hash.new
            class << self
                attr_reader :options
                def font_size;  options[:font_size] || 12 end
                def height;     options[:height] || 16 end
                def interline
                    options[:interline] || (font_size + height * 2)
                end
                def event_radius; options[:event_radius] || height / 4 end
                def spacing; options[:spacing] || (event_radius * 2) end
            end

            # Builds a canvas group which displays the task itself
            def self.node(group, task)
                events = task.bound_events

                width = if events.size > 2
                            height * (events.size - 1)
                        end
                width = height * 2 unless width && (width > height * 2)

                group.g do |node|
                    node.styles(:stroke=>'black', :stroke_width=>1, :fill => 'white')

                    class << node
                        attr_accessor :task, :events
                        attr_accessor :x, :y, :height, :width
                    end
                    node.width  = width + event_radius * 2
                    node.height = height + font_size
                    node.events = Hash.new
                    node.task   = task

                    left_x = -width / 2
                    node.rect(width, height, left_x, 0).
                        styles :stroke_width => 1
                    node.text(0, 0, task.model.name).
                        styles :text_anchor => 'middle', :font_size => font_size, :font_weight => 'lighter'

                    ev_spacing = width / (events.size - 1)
                    events.each_with_index do |ev, idx|
                        spot = node.circle(event_radius, left_x + idx * ev_spacing, height / 2).
                            styles :stroke => 'black', :stroke_width => 2
                        if ev.model.symbol == :start
                            spot.styles :stroke => '#00BB00'
                        else
                            spot.styles :stroke => '#BB0000'
                        end
                        node.events[ev] = spot
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
                def display(group)
                    Graph.node(group, node)
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
                            next unless parents
                            parents.each { |p| 
                                graph_group.line(tree[child].display_group.x, index * interline, 
                                           tree[p].display_group.x, level_of[p] * interline + height) 
                            }
                        end
                    end
                end
            end

            def self.tree(group, root, enum_with = :each_child)
                children = root.enum_for(enum_with).to_a
                if children.empty?
                    return root.display_group = root.display(group)
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
                    root.display(parent_group)
                end
            end
        end
    end
end

if $0 == __FILE__
    class EventMockup
        attr_reader :name
        Model = Struct.new :symbol
        def initialize(name, terminal = false); @name, @terminal = name, terminal end
        def terminal?; @terminal end
        def model; Model.new name.to_sym end
    end
    class TaskMockup
        attr_reader :name, :children
        def initialize(name)
            @name = name 
            @children = []
        end
        def bound_events 
            [ EventMockup.new(:start, false), EventMockup.new(:stop, true) ]
        end

        Model = Struct.new(:name)
        def model
            m = Model.new
            m.name = name
            m
        end

        def each_child(&iterator); @children.each(&iterator) end
    end

    def fill_canvas(canvas)
        canvas.background_fill = 'white'

        root = TaskMockup.new('root')
        left = TaskMockup.new('left')
        right = TaskMockup.new('right')
        root.children << left << right
        common = TaskMockup.new 'common'
        left.children << common
        right.children << common
        
        include Roby::Display
        Graph.hierarchy(canvas, root).translate(128, 16)
        #Roby::Display::Graph.hier
        #    #graph.node(canvas, root).translate(128, 16)
        #    #graph.tree(canvas, root).translate(128, 16)
        #    graph.
        #end
    end

    if true
        require 'RMagick'
        require 'rvg/rvg'

        include Magick
        RVG::dpi = 100
        canvas = RVG.new(512, 256)
        fill_canvas(canvas)
    end

    if false
        canvas.draw.display
    end
    
    if true
        canvas.draw.write('plan.png')

        require 'Qt'
        require 'rvg-qt'
        include Qt
        a = Application.new( ARGV )

        canvas = Canvas.new(512, 256)
        fill_canvas(canvas)

        view   = CanvasView.new(canvas)
        a.setMainWidget( view )
        view.show()
        canvas.update()
        view.update()
        a.exec()
    end
end

