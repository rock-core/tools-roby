module Roby::EventStructure
    relation :EnsuredEvent, :noinfo => true do
	def calling(context)
	    super if defined? super

            if ev = find_ensured_event { |ev| !ev.happened? }
                postpone(ev, "waiting for ensured event #{ev}") do
                    ev.call(context) if ev.controlable?
                end
            end
	end

	def ensure(event)
	    add_ensured_event event
	end
    end
end

