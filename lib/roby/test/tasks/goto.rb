
module Roby
    module Test
	class Goto2D < Roby::Task
	    terminates
	    argument :x, :y

	    def speed; State.speed end
	    def x; arguments[:x] end
	    def y; arguments[:y] end

	    poll do
		dx = x - State.pos.x
		dy = y - State.pos.y
		d = Math.sqrt(dx * dx + dy * dy)
		if d > speed
		    State.pos.x += speed * dx / d
		    State.pos.y += speed * dy / d
 		else
		    State.pos.x = x
		    State.pos.y = y
		end
	    end

	    module Planning
		planning_library
		method(:go_to) do
		    Goto2D.new(arguments)
		end
	    end
	end
    end
end

