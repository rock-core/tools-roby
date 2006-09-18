require 'utilrb/enumerable'
require 'utilrb/value_set'
require 'roby/bgl'


module BGL
    module Vertex
	def clear
	    each_graph { |g| g.remove(self) }
	end
    end
end

