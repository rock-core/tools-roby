# frozen_string_literal: true

class Cylinder
    attr_accessor :radius, :height, :axis
    def initialize(radius, height, axis)
        @radius, @height, @axis = radius.to_f, height.to_f, axis.to_f
    end

    def diameter(axis)
        if axis == self.axis
            radius * 2
        else
            raise NotImplementedError
        end
    end
    alias max_length diameter
    def length
        diameter(:z)
    end

    def width
        diameter(:z)
    end
end

class Cube
    attr_accessor :length, :width, :height
    def initialize(length, width, height)
        @length, @width, @height = length.to_f, width.to_f, height.to_f
    end

    def max_length(axis)
        if axis == :z
            [length, width].max
        else
            height
        end
    end
end
