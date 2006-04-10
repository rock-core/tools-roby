require 'roby/event'
require 'roby/relations'
require 'roby/relations/signals'

module Roby::EventStructure
    relation :causal_link do
	superset_of Signals
    end
end

