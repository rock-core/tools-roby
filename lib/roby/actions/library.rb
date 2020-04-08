# frozen_string_literal: true

module Roby
    module Actions
        Library = Models::Library.new
        Library.root = true
    end
end

class Module
    def action_library(name = nil, &block)
        if name
            create_and_register_submodel(self, name, Roby::Actions::Library, &block)
        else
            extend Roby::Actions::Models::Interface
            extend MetaRuby::ModelAsModule
            extend MetaRuby::Registration
            self.supermodel = Roby::Actions::Library
            Roby::Actions::Library.register_submodel(self)
        end
    end
end
