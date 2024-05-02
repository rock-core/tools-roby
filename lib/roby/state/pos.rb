# frozen_string_literal: true

# A namespace in which are defined position-related classes.
module Roby::Pos
    # A (x, y, z) vector
    class Vector3D
        # The vector coordinates
        attr_accessor :x, :y, :z

        # Initializes a 3D vector
        def initialize(x = 0, y = 0, z = 0)
            @x, @y, @z = x, y, z
        end

        def to_s # :nodoc:
            format("Vector3D(x=%f,y=%f,z=%f)", x, y, z)
        end

        def pretty_print(pp)
            pp.text to_s
        end

        # The length of the vector
        def length
            distance(0, 0, 0)
        end

        # Returns self + v
        def +(other)
            Vector3D.new(x + other.x, y + other.y, z + other.z)
        end

        # Returns self - v
        def -(other)
            Vector3D.new(x - other.x, y - other.y, z - other.z)
        end

        # Returns the product of this vector with the scalar +a+
        def *(other)
            Vector3D.new(x * other, y * other, z * other)
        end

        # Returns the division of this vector with the scalar +a+
        def /(other)
            Vector3D.new(x / other, y / other, z / other)
        end

        # Returns the opposite of this vector
        def -@
            Vector3D.new(-x, -y, -z)
        end

        # Returns the [x, y, z] array
        def xyz
            [x, y, z]
        end

        # True if +v+ is the same vector than +self+
        def ==(other)
            other.kind_of?(Vector3D) &&
                other.x == x && other.y == y && other.z == z
        end

        # True if this vector is of zero length. If +tolerance+ is non-zero,
        # returns true if length <= tolerance.
        def null?(tolerance = 0)
            length <= tolerance
        end

        # call-seq:
        #   v.distance2d w
        #   v.distance2d x, y
        #
        # Returns the euclidian distance in the (X,Y) plane, between this vector
        # and the given coordinates. In the first form, +w+ can be a vector in which
        # case the distance is computed between (self.x, self.y) and (w.x, w.y).
        # If +w+ is a scalar, it is taken as the X coordinate and y = 0.
        #
        # In the second form, both +x+ and +y+ must be scalars.
        def distance2d(x = 0, y = nil)
            if !y && x.respond_to?(:x)
                x, y = x.x, x.y
            else
                y ||= 0
            end

            Math.sqrt(((x - self.x)**2) + ((y - self.y)**2))
        end

        # call-seq:
        #   v.distance2d w
        #   v.distance2d x, y
        #   v.distance2d x, y, z
        #
        # Returns the euclidian distance in the (X,Y,Z) space, between this vector
        # and the given coordinates. In the first form, +w+ can be a vector in which
        # case the distance is computed between (self.x, self.y, self.z) and (w.x, w.y, w.z).
        # If +w+ is a scalar, it is taken as the X coordinate and y = z = 0.
        #
        # In the second form, both +x+ and +y+ must be scalars and z == 0.
        def distance(x = 0, y = nil, z = nil)
            if !y && x.respond_to?(:x)
                x, y, z = x.x, x.y, x.z
            else
                y ||= 0
                z ||= 0
            end

            Math.sqrt(((x - self.x)**2) + ((y - self.y)**2) + ((z - self.z)**2))
        end
    end

    # This class represents both a position and an orientation
    class Euler3D < Vector3D
        # The orientation angles
        attr_accessor :yaw, :pitch, :roll

        # Create an euler position object
        def initialize(x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0)
            super(x, y, z)
            @yaw, @pitch, @roll = yaw, pitch, roll
        end

        # Returns [yaw, pitch, roll]
        def ypr
            [yaw, pitch, roll]
        end

        def to_s # :nodoc:
            format("Euler3D(x=%f,y=%f,z=%f,y=%f,p=%f,r=%f)", x, y, z, yaw, pitch, roll)
        end
    end
end
