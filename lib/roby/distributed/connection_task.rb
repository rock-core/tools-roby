module Roby
    module Distributed
        # Representation of an established peer connection in the Roby plan
        class ConnectionTask < Roby::Task
            local_only

            argument :peer
            event :ready

            event :aborted, :terminal => true do |context|
                peer.disconnected!
            end
            forward :aborted => :failed

            event :failed, :terminal => true do |context| 
                peer.disconnect
            end
            interruptible
        end
    end
end


