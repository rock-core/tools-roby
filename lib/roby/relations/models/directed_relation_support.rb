module Roby
    module Relations
        module Models
            module DirectedRelationSupport
                include MetaRuby::Attributes
                attribute(:relation_spaces) { Array.new }
                attribute(:all_relation_spaces) { Array.new }
            end
        end
    end
end
