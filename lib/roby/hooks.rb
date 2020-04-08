# frozen_string_literal: true

module Roby
    # Override of the global Hooks behaviour w.r.t. blocks. Blocks are evaluated
    # in their definition context in Roby instead of the default evaluation in
    # the context of the receiver
    module Hooks
        include ::Hooks

        def self.included(base)
            base.class_eval do
                extend Uber::InheritableAttr
                extend ClassMethods
                inheritable_attr :_hooks
                self._hooks = HookSet.new
            end
        end

        module ClassMethods
            include ::Hooks::ClassMethods

            def define_hooks(callback, scope: ->(c, s) { s unless c.proc? })
                super
            end
        end
    end
end
