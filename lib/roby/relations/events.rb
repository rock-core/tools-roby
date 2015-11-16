module Roby::EventStructure
    relation :Signal, noinfo: true
    relation :Forwarding, noinfo: true
    relation :CausalLink, subsets: [Signal, Forwarding], noinfo: true
    relation :Precedence, subsets: [CausalLink], noinfo: true
end

