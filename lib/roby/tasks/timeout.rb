module Roby
    module Tasks
        class Timeout < Roby::Task
            argument :delay
            terminates

            event :timed_out
            forward timed_out: :stop

            event :start do |context|
                start_event.forward_to timed_out_event, delay: delay
                start_event.emit
            end
        end
    end
end

