require 'roby/event'
require 'roby/relations'

module Roby::EventStructure
    event_relation CausalLinks do
	enumerators nil, :causal_link
    end
end

