require 'roby/support'

module Qt
    module CanvasItemOperations
        def qt_attr_apply(name, method, *args, &proc)
            current = send(name)
            current.send("#{method}=", *args, &proc)
            send("#{name}=", current)
        end

        def translate(tx, ty = 0)
            moveBy(tx, ty)
            yield(self) if block_given?
            self
        end
        def styles(options, &block)
            yield(self) if block_given?
            self
        end
    end

    module PolygonalItemStyles
        def styles(options)
            if options[:stroke]
                qt_attr_apply(:pen, :color, Color.new(options[:stroke]))
            end
            if options[:stroke_width]
                qt_attr_apply(:pen, :width, Integer(options[:stroke_width]))
            end
            if options[:fill]
                qt_attr_apply(:brush, :color, Color.new(options[:fill]))
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
            if @inner
                if options[:fill]
                    @inner.styles :fill => options[:fill]
                end
                if options[:stroke_width]
                    new_inner_size = size - options[:stroke_width]
                    @inner.setSize(new_inner_size, new_inner_size)

                    new_outer_size = size + options[:stroke_width]
                    setSize(new_outer_size, new_outer_size)
                end
                if options[:stroke]
                    super :fill => options[:stroke]
                end
            end
            super if defined? super
        end
    end
    class CanvasText
        RVG_TO_QT_ALIGNMENT = { :start => AlignLeft, :middle => AlignHCenter, :right => AlignRight }
        RVG_TO_QT_FONT_WEIGHT = { :normal => 25, :bold => 75, :bolder => 87, :lighter => 25 }
        RVG_VALIGN = AlignBottom

        include CanvasItemOperations

       
        def styles(options)
            if options[:text_anchor]
                self.text_flags = RVG_VALIGN + RVG_TO_QT_ALIGNMENT[options[:text_anchor].to_sym]
            end

            if options[:font_family]
                qt_attr_apply(:font, :family, options[:font_family])
            end
            if options[:font_weight]
                weight = options[:font_weight]
                weight = begin
                             Integer(weight) / 10
                         rescue ArgumentError
                             RVG_TO_QT_FONT_WEIGHT[weight.to_sym]
                         end
                qt_attr_apply(:font, :weight, weight)
            end
            if options[:font_size]
                qt_attr_apply(:font, :pixel_size, Integer(options[:font_size]))
            end
            super if defined? super
        end
    end

    class Canvas
        def background_fill=(color)
            self.background_color = Color.new(color)
        end
        @@z = 0

        def rect(w, h, x = 0, y = 0)
            CanvasRectangle.new(x, y, w, h, self) do |shape|
                shape.visible = true
                shape.brush = Brush.new(Color.new('black'))
                shape.z = (@@z += 1)
                yield(shape) if block_given?
            end
        end
        def circle(r, x = 0, y = 0)
            # Emulate the possibility to have a pen in canvasellipse by using two circles
            setup = lambda do |shape|
                shape.visible = true
                shape.translate(x, y)
                shape.z = (@@z += 1)
                shape.brush = Brush.new(Color.new('black'))
            end
            outer = CanvasEllipse.new((r + 1) * 2 , (r + 1) * 2, self, &setup)
            inner = CanvasEllipse.new(r * 2 , r * 2, self, &setup)
            outer.instance_variable_set("@inner", inner)
            outer.styles :stroke => 'black', :stroke_width => 1, :fill => 'black'

            yield(outer) if block_given?
            outer
        end
        def text(x = 0, y = 0, text = nil)
            CanvasText.new(text, self) do |shape|
                shape.translate(x, y)
                shape.text_flags = CanvasText::RVG_VALIGN + AlignLeft
                shape.z = (@@z += 1)
                shape.visible = true
                yield(shape) if block_given?
            end
        end

        def line(x1 = 0, y1 = 0, x2 = 0, y2 = 0)
            CanvasLine.new(self) do |shape|
                shape.setPoints(x1, y1, x2, y2)
                shape.z = (@@z += 1)
                shape.visible = true
                yield(shape) if block_given?
            end
        end

        def group(&block)
            Group.new(self, &block)
        end
        alias :g :group

        class Group
            attr_reader :canvas
            def initialize(canvas)
                @canvas = canvas
                @objects = []
                @pending = Array.new
                yield(self) if block_given?
            end

            def translate(*args, &block); apply(:translate, *args, &block) end
            def styles(options); apply(:styles, options) end
            def apply(name, *args, &block)
                @pending << [name, args, block]
                @objects.each { |obj| obj.send(name, *args, &block) }
                self
            end

            def g(*args, &block); shape(:g, *args, &block) end
            def circle(*args, &block); shape(:circle, *args, &block) end
            def rect(*args, &block); shape(:rect, *args, &block) end
            def text(*args, &block); shape(:text, *args, &block) end
            def line(*args, &block); shape(:line, *args, &block) end
            def shape(type, *args)
                canvas.send(type, *args) do |shape|
                    @pending.each do |name, args, block|
                        shape.send(name, *args, &block)
                    end

                    @objects << shape
                    yield(shape) if block_given?
                end
            end
        end
    end
end

