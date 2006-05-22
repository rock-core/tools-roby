require 'roby/event'
require 'roby/relations'
require 'roby/relations/signals'

module Roby::EventStructure
    relation :causal_link do
	superset_of Signals
	superset_of Forwardings

	# For now, we only issue a debugging warning if a particular event
	# is pending and it is not active
	def called(context)
	    super if defined? super

	    if pending > 0 && !active?
		Roby.warn { "#{self} has pending events, but it is not active" }
	    end
	end
    end
end

