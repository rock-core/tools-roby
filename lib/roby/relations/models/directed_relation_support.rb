# frozen_string_literal: true

module Roby
    module Relations
        module Models
            module DirectedRelationSupport
                include MetaRuby::Attributes
                attribute(:relation_spaces) { [] }
                attribute(:all_relation_spaces) { [] }
            end
        end
    end
end
