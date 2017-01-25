module Roby
    module Actions
        module Models
            # Metamodel for action libraries
            class Library < Module
                include Models::InterfaceBase
                include MetaRuby::ModelAsModule
                include MetaRuby::Registration
            end
        end
    end
end
