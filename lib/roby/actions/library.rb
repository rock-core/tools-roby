module Roby
    module Actions
        module Library
            include Roby::Actions::InterfaceModel
            extend Utilrb::Models::Registration

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

