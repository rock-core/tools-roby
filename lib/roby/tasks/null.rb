module Roby
    module Tasks
        # A special task model which does nothing and emits +success+
        # as soon as it is started.
        class Null < Task
            event :start, command: true
            event :stop
            forward start: :success

            # Always true. See Task#null?
            def null?; true end
        end
    end

    # For backward-compatibility only
    NullTask = Tasks::Null
end


