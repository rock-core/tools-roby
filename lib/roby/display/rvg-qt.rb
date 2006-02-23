require 'roby/support'

module Qt
    module CanvasItemOperations
        def qt_attr_apply(name, method, *args, &proc)
            current = send(name)
            current.send("#{method}=", *args, &proc)
            send("#{name}=", current)
        end

        # SVG declaration for this element
        attr_accessor :kind, :options
        def to_svg(xm, &block)
            attributes = options.merge(@styles || {})
            attributes = Hash[*attributes.map { |k, v| [ k.to_s.gsub(/_/, '-'), v ] }.flatten]
            xm.tag! kind, attributes, &block
        end

        def translate(tx, ty = 0)
            moveBy(tx, ty)
            yield(self) if block_given?
            self
        end
        private :translate

        def styles(options)
            @styles ||= Hash.new
            @styles.merge! options
            
            yield(self) if block_given?
            self
        end

        alias :apply :send
    end

    module PolygonalItemStyles
        def styles(options)
            options.each do |name, value|
                case name.to_sym
                when :stroke
                    qt_attr_apply(:pen, :color, Color.new(value))
                when :stroke_width
                    qt_attr_apply(:pen, :width, Integer(value))
                when :fill
                    qt_attr_apply(:brush, :color, Color.new(value))
                end
            end
            super if defined? super
        end
    end
    class CanvasRectangle
        include CanvasItemOperations
        include PolygonalItemStyles
    end
    class CanvasLine
        include CanvasItemOperations
        include PolygonalItemStyles
    end
    class CanvasEllipse
        include CanvasItemOperations
        include PolygonalItemStyles

        attr_reader :size
        def initialize(s, *args)
            @size = s
            super
        end

        def translate(*args, &block)
            @inner.translate(*args) if @inner
            super
        end

        def styles(options)
            super(options) if defined? super
            if @inner
                options.each do |name, value|
                    case name.to_sym
                    when :fill
                        @inner.styles :fill => value
                    when :stroke_width
                        new_inner_size = size - value
                        @inner.setSize(new_inner_size, new_inner_size)

                        new_outer_size = size + value
                        setSize(new_outer_size, new_outer_size)
                    when :stroke
                        qt_attr_apply(:brush, :color, Color.new(value))
                    end
                end
            end
            yield(self) if block_given?
            self
        end
    end
    class CanvasText
        RVG_TO_QT_ALIGNMENT = { :start => AlignLeft, :middle => AlignHCenter, :right => AlignRight }
        RVG_TO_QT_FONT_WEIGHT = { :normal => 25, :bold => 75, :bolder => 87, :lighter => 25 }
        RVG_VALIGN = AlignBottom

        include CanvasItemOperations
       
        def styles(options)
            options.each do |name, value|
                case name.to_sym
                when :text_anchor
                    self.text_flags = RVG_VALIGN + RVG_TO_QT_ALIGNMENT[value.to_sym]
                when :font_family
                    qt_attr_apply(:font, :family, value)
                when :font_weight
                    weight = if RVG_TO_QT_FONT_WEIGHT.has_key?(value.to_sym)
                                 RVG_TO_QT_FONT_WEIGHT[value.to_sym]
                             else
                                 Integer(value) / 10
                             end
                    qt_attr_apply(:font, :weight, weight)
                when :font_size
                    qt_attr_apply(:font, :pixel_size, Integer(value))
                end
            end
            super if defined? super
        end

        def to_svg(xm)
            super(xm) do
                xm.text! text
            end
        end
    end

    module RVGGroup
        #
        # Shapes
        #
        def shape(klass, user_block, *args)
            klass.new(*args) do |shape|
                shape.z = Canvas.new_z

                # specific setup for this shape
                yield(shape)        if block_given?
                pending.each do |name, args, block|
                    shape.send(name, *args, &block)
                end

                # user setup of the new item, must be done after
                # yield() setup as the user may want to override
                # values set in yield()
                user_block[shape]   if user_block
            end
        end

        def rect(w, h, x = 0, y = 0, &block)
            shape(Qt::CanvasRectangle, block, x, y, w, h, canvas) do |shape|
                shape.brush = Brush.new(Color.new('black'))
                shape.kind      = 'rect'
                shape.options   = { :x => x, :y => y, :width => w, :height => h }
                shape.styles    :stroke => 'black'
                objects << shape
            end
        end
        def circle(r, x = 0, y = 0, &block)
            # Emulate the possibility to have a pen in canvasellipse by using two circles
            setup = lambda do |shape|
                shape.send(:translate, x, y)
                shape.brush = Brush.new( Color.new('black') )

                shape.kind      = :circle
                shape.options   = { :r => r, :cx => x, :cy => y }
            end
            inner = shape(CanvasEllipse, nil, (r - 1) * 2 , (r - 1) * 2, canvas, &setup)
            outer = shape(CanvasEllipse, block, r * 2 , r * 2, canvas) do |outer|
                setup[outer]
                outer.instance_variable_set("@inner", inner)
                outer.z, inner.z = inner.z, outer.z
                outer.styles :stroke => 'black', :stroke_width => 1, :fill => 'black'
                objects << outer
            end

            outer
        end

               
        def text(x = 0, y = 0, text = nil, &block)
            shape(CanvasText, block, text, canvas) do |shape|
                shape.send(:translate, x, y)
                shape.text_flags = CanvasText::RVG_VALIGN + Qt::AlignLeft

                shape.kind      = :text
                shape.options   = { :x => x, :y => y }
                shape.styles    :stroke => 'black'
                objects << shape
            end
        end
        def line(x1 = 0, y1 = 0, x2 = 0, y2 = 0, &block)
            shape(CanvasLine, block, canvas) do |shape|
                shape.setPoints(x1, y1, x2, y2)

                shape.kind      = :line
                shape.options   = { :x1 => x1, :y1 => y1, :x2 => x2, :y2 => y2 }
                shape.styles    :stroke => 'black'
                objects << shape
            end
        end
        def g
            Canvas::Group.new(self) do |group|
                yield(group) if block_given?
                objects << group
            end
        end

        attribute(:xform)   { Array.new }
        attribute(:pending) { Array.new }
        attribute(:objects) { Array.new }

        # :section: transformations
        
        # translation of the whole group
        def translate(tx, ty = 0, &block) 
            apply(:translate, tx, ty, &block) 
            xform << "translate(#{tx}, #{ty})"
            self
        end
        # group-wide styles
        def styles(options)
            apply(:styles, options) 
            @styles ||= Hash.new
            @styles.merge! options
        end
        def visible=(value); apply(:visible=, value) end

        # Common handling of transformations
        def apply(name, *args, &block)
            pending << [name, args, block]
            objects.each { |obj| obj.send(:apply, name, *args, &block) }
            self
        end
        private :apply

        # SVG rendering
        def to_svg(xm = nil)
            if !xm
                xm = Builder::XmlMarkup.new :indent => 4
                xm.instruct!
                return xm.svg { to_svg(xm) }
            end

            attributes = {}
            attributes.merge!(@styles || {})
            attributes.merge!(:transform => xform.join(" ")) unless xform.empty?

            xm.g(attributes) do
                objects.each { |obj| obj.to_svg(xm) }
            end
        end
    end

    class Canvas
        include RVGGroup

        def canvas; self end
        def background_fill=(color)
            self.background_color = Color.new(color)
        end
        
        @@z = 0
        def self.new_z; @@z += 1 end

        class Group
            include RVGGroup
            attr_reader :canvas

            def initialize(canvas)
                @canvas = canvas.canvas
                yield(self) if block_given?
            end
        end
    end
end

