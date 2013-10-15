module Roby
    module Interface
        # Exception thrown when something is wrong in the client/server protocol
        class ProtocolError < RuntimeError
        end

        # Exception thrown when connection cannot be created
        class ConnectionError < RuntimeError
        end

        # Exception thrown when the IO channel should be considered as broken
        class ComError < RuntimeError
        end
    end
end

