# frozen_string_literal: true

module Roby
    module Tasks
        # This task model is a simple task where +start+, +success+ and
        # +failed+ are pass-through controlable events. They have an +id+
        # argument which is automatically set to the object's #object_id if not
        # explicitely given at initialization.
        class Simple < Roby::Task
            argument :id

            def initialize(**arguments) # :nodoc:
                super(id: object_id.to_s, **arguments)
            end

            event :start, command: true
            event :success, command: true, terminal: true
            terminates
        end
    end
end
