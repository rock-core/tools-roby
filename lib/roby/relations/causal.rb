require 'roby/event'

module Roby::EventStructure
    module CausalLinks
        attribute(:causal_links) { Array.new }

        def each_causal_link(&iterator)
            each_signal(&iterator)
            causal_links.each(&iterator)
        end
    end
end

class Roby::EventGenerator
    include Roby::EventStructure::CausalLinks
end

