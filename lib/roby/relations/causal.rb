require 'roby/event'
require 'roby/relations'
require 'roby/relations/signals'

module Roby::EventStructure
    relation :causal_link, :subsets => [Signals, Forwardings], :noinfo => true
end

