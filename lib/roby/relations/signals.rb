require 'roby/event'
module Roby::EventStructure
    relation :Signal, :noinfo => true do
	# Returns true if the two events are linked via a signal one
	# way or the other
	def eqv?(other)
	    self.child_object?(other, Roby::EventStructure::Signal) || 
		other.child_object?(self, Roby::EventStructure::Signal)
	end
    end

    relation :Forwarding, :noinfo => true
end

