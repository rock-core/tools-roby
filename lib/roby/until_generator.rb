module Roby
    # This event generator combines a source and a limit in a temporal pattern.
    # The generator acts as a pass-through for the source, until the limit is
    # itself emitted. It means that:
    #
    # * before the limit is emitted, the generator will emit each time its
    #  source emits 
    # * since the point where the limit is emitted, the generator
    #   does not emit anymore
    #
    # See also EventGenerator#until
    class UntilGenerator < Roby::EventGenerator
        # Creates a until generator for the given source and limit event
        # generators
	def initialize(source = nil, limit = nil)
	    super() do |context|
		plan.remove_object(self) if plan 
		clear_relations
	    end

	    if source && limit
		source.forward_to(self)
		limit.signals(self)
	    end
	end
    end
end

