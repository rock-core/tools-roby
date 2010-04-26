module Roby
    module Tasks
        class Timeout < Roby::Task
            arguments :delay
            terminates

            event :start do |context|
                forward :start, self, :stop, :delay => delay
                emit :start
            end
        end
    end
end

