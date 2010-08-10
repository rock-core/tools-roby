module Roby
    module Tasks
        class Timeout < Roby::Task
            arguments :delay
            terminates

            event :timed_out
            forward :timed_out => :stop

            event :start do |context|
                forward_to :start, self, :timed_out, :delay => delay
                emit :start
            end
        end
    end
end

