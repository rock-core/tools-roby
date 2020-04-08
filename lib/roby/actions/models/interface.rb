# frozen_string_literal: true

module Roby
    module Actions
        module Models
            module Interface
                include Models::InterfaceBase
                include MetaRuby::ModelAsClass

                # @api private
                #
                # Internal handler for MetaRuby's inherited-attribute functionality.
                # It updates an action from a parent model to match this model.
                #
                # In particular, it updates coordination models to point to actions
                # of this
                def promote_registered_action(name, action)
                    actions[name] ||= action.rebind(self)
                end
            end
        end
    end
end
