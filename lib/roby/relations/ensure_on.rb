module Roby::EventStructure
    relation Ensured do
	relation_name :ensured_event

	def calling(context)
	    super if defined? super
	    each_ensured_event do |ev|
		if !ev.happened?
		    ev.on self
		    ev.add_causal_link self
		    ev.call(context)
		    throw :filtered
		end
	    end
	end

	def ensure_on(event)
	    event.add_ensured_event self
	end
    end
end

