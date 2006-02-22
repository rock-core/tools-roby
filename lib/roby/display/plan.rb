require 'roby/support'

module Roby
    module Display
        class Graph
            def initialize(options = Hash.new)
                @nodes      = Hash.new
                @options    = options
                yield(self) if block_given?
            end

            attr_reader :options
            def font_size;  options[:font_size] || 12 end
            def height;     options[:height] || 16 end
            def interline
                options[:interline] || (font_size + height * 2)
            end
            def event_radius; options[:event_radius] || height / 4 end
            def spacing; options[:spacing] || (event_radius * 2) end

            # Builds a canvas group which displays the task itself
            def node(group, task)
                events = task.bound_events

                width = if events.size > 2
                            height * (events.size - 1)
                        end
                width = height * 2 unless width && (width > height * 2)

                group.g do |node|
                    node.styles(:stroke=>'black', :stroke_width=>1, :fill => 'white')

                    class << node
                        attr_accessor :events
                        attr_accessor :height, :width
                    end
                    node.width = width + event_radius * 2
                    node.height = height + font_size
                    node.events = Hash.new

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

            def hierarchy(group, root, enum_with = :each_child)
                children = root.enum_for(enum_with).to_a
                if children.empty?
                    node(group, root)
                else
                    group.g do |parent_group|
                        children_group = parent_group.g do |children_group|
                            # Build the hierarchy graphs for each child
                            children.map! { |child| hierarchy(children_group, child) }

                            # Compute the subgroup width
                            class << children_group; attr_accessor :width end
                            children_group.width = line_width = 
                                children.inject(0) { |w, child| w + child.width } + spacing * (children.size - 1)

                            # Create the horizontal part of the connector
                            connector_y = [-interline / 4, -font_size].min
                            if (children.size > 1)
                                children_group.line(-line_width / 2 + children.first.width / 2, connector_y, 
                                                    line_width / 2 - children.last.width / 2, connector_y)
                            end

                            # Move each child and connect them to the connector
                            x = -line_width / 2
                            children.each do |child|
                                child_x = (x + child.width / 2)

                                child.translate(child_x, 0)
                                children_group.line(child_x, 0, child_x, connector_y) if children.size > 1
                                                    
                                x = x + child.width + spacing
                            end
                        end
                        # Move the children
                        children_group.translate(0, interline)
                        
                        # Connect the parent to the connector
                        if children.size > 1
                            parent_group.line(0, 0, 0, 3 * interline / 4)
                        else
                            parent_group.line(0, 0, 0, interline)
                        end
                        # Build the parent node
                        node(parent_group, root)
                    end
                end
            end

            # Add a signal between parent and child
            def signal(parent, child)
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
        
        Roby::Display::Graph.new do |graph|
            #graph.node(canvas, root).translate(128, 16)
            graph.hierarchy(canvas, root).translate(128, 16)
        end
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

