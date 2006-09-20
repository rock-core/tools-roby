require 'roby/event'
require 'roby/relations'
require 'roby/relations/signals'

module Roby::EventStructure
    relation :CausalLink, :subsets => [Signal, Forwarding], :noinfo => true
end

