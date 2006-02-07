class Cylinder
    attr_accessor :radius
    attr_accessor :height
    def initialize(radius, height = nil)
        @radius, @height = radius, height
    end
    def diameter;   radius * 2 end
    alias :max_length :diameter 
end


