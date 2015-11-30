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

        # Exception thrown when attempting an operation in an unsupported state
        # (such as e.g. calling an operation on an unattached {Async} object
        # that requires the object to be attached
        class InvalidState < RuntimeError
        end
    end
end

