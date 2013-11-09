module Roby
    # Modifies an event context
    #
    # See EventGenerator#filter for details
    class FilterGenerator < EventGenerator
	def initialize(user_context, &block)
	    if block && !user_context.empty?
		raise ArgumentError, "you must set either the filter or the value, not both"
	    end

	    if block
		super() do |context| 
		    context = context.map do |val|
			block.call(val)
		    end
		    emit(*context)
		end
	    else
		super() do 
		    emit(*user_context)
		end
	    end
	end
    end
end

