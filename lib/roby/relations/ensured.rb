require 'roby/event'
module Roby::EventStructure
    module EnsuredEventSupport
	def calling(context)
	    super if defined? super
	    each_ensured_event do |ev|
		if !ev.happened?
		    postpone(ev, "waiting for ensured event #{ev}") do
			ev.call(context) if ev.controlable?
		    end
		end
	    end
	end

	def ensure(event)
	    add_ensured_event event
	end
    end

    relation :EnsuredEvent, :noinfo => true
end

