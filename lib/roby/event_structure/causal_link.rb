# frozen_string_literal: true

module Roby
    module EventStructure
        relation :CausalLink, subsets: [Signal, Forwarding], noinfo: true
    end
end
