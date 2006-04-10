module Roby::EventStructure
    relation :ensured_event do
	def calling(context)
	    super if defined? super
	    each_ensured_event do |ev|
		if !ev.happened?
		    ev.on self
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

