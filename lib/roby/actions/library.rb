module Roby
    module Actions
        module Library
            include Models::Interface
            include MetaRuby::ModelAsModule
            extend MetaRuby::Registration

            attr_accessor :supermodel

            def self.supermodel; end
        end
    end
end

class Module
    def action_library
        extend Roby::Actions::Library
        self.supermodel = Roby::Actions::Library
        Roby::Actions::Library.register_submodel(self)
    end
end

