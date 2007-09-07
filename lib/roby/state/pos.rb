module Roby::Pos
    class Vector3D
	attr_accessor :x, :y, :z

	def initialize(x = 0, y = 0, z = 0)
	    @x, @y, @z = x, y, z
	end

	def to_s; "#<Vector3D (x,y,z) = (%f,%f,%f)>" % [x,y,z] end

	def length; distance(0, 0, 0) end
	def +(v); Vector3D.new(x + v.x, y + v.y, z + v.z) end
	def -(v); Vector3D.new(x - v.x, y - v.y, z - v.z) end
	def *(a); Vector3D.new(x * a, y * a, z * a) end
	def /(a); Vector3D.new(x / a, y / a, z / a) end

	def xyz; [x, y, z] end

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

    class Euler3D < Vector3D
	attr_accessor :yaw, :pitch, :roll
	def initialize(x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0)
	    super(x, y, z)
	    @yaw, @pitch, @roll = yaw, pitch, roll
	end

	def ypr
	    [yaw, pitch, roll]
	end

	def to_s; "#<Euler3D (x,y,z) = (%f,%f,%f); (y,p,r) = (%f,%f,%f)>" % [x,y,z,yaw,pitch,roll] end
    end
end

