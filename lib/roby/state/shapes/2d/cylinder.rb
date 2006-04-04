class Cylinder
    attr_accessor :radius, :height, :axis
    def initialize(radius, height, axis)
        @radius, @height, @axis = radius, height, axis
    end
    def diameter(axis)
	if axis == self.axis
	    radius * 2
	else
	    raise NotImplementedError
	end
    end
    alias :max_length :diameter 
end


