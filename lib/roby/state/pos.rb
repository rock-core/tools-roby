module Roby::Pos
    class Euler3D
	attr_accessor :x, :y, :z, :yaw, :pitch, :roll
	def initialize(x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0)
	    @x, @y, @z, @yaw, @pitch, @roll =
		x, y, z, yaw, pitch, roll
	end

	def to_s; "#<Euler3D (x,y,z) = (%f,%f,%f); (y,p,r) = (%f,%f,%f)>" % [x,y,z,yaw,pitch,roll] end
	def distance(x = 0, y = nil, z = nil)
	    if !y && x.respond_to?(:x)
		x, y, z = x.x, x.y, x.z
	    else
		y ||= 0
		z ||= 0
	    end

	    Math.sqrt( (x - self.x) ** 2 + (y - self.y) ** 2 + (z - self.z) ** 2)
	end
    end
end

