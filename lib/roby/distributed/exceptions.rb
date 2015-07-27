module Roby
    module Distributed
        # Base class for all communication errors
        class ConnectionError   < RuntimeError; end
        # Raised when a connection attempt has failed
        class ConnectionFailedError < RuntimeError
            def initialize(peer); @peer = peer end
        end
        # The peer is connected but connection is not alive
        class NotAliveError     < ConnectionError; end
        # The peer is disconnected
        class DisconnectedError < ConnectionError; end

        # Base class for all errors in the dRoby protocol
        class ProtocolError < RuntimeError
        end

        # Exception raised when the local plan manager gets a RemoteID for which
        # we don't have any proxy registered (this should not happen)
        class MissingProxyError < ProtocolError
            attr_reader :remote_id

            def initialize(remote_id)
                @remote_id = remote_id
            end

            def pretty_print(pp)
                pp.text "no proxy registered for remote ID #{remote_id}"
            end
        end

	class InvalidRemoteOperation < RuntimeError; end

	class InvalidRemoteTaskOperation < InvalidRemoteOperation
	    attr_reader :task
	    def initialize(task); @task = task end
	end

        # Exception raised when a remote peer sends us remote sibling
        # information that is inconsistent with the one we know
        class SiblingMismatchError < ProtocolError
            attr_reader :object
            attr_reader :siblings
            attr_reader :peer_id
            attr_reader :remote_id

            def initialize(object, peer_id, remote_id)
                @object = object
                @siblings = object.remote_siblings.dup
                @peer_id = peer_id
                @remote_id = remote_id
            end

            def pretty_print(pp)
                pp.text "there is an inconsistency on the remote siblings of"
                pp.breakable
                object.pretty_print(pp)
                pp.breakable
                pp.text "known siblings are:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(siblings) do |pair|
                        peer_id, remote_id = *pair
                        pp.text "#{peer_id} => #{remote_id}"
                    end
                end
                pp.breakable
                pp.text "the offending sibling is"
                pp.nest(2) do
                    pp.breakable
                    pp.text "#{peer_id} => #{remote_id}"
                end
            end
        end

        # Error raised when a connection attempt failed on the given neighbour
	class ConnectionFailed < RuntimeError
	    attr_reader :neighbour

	    def initialize(neighbour)
		@neighbour = neighbour
	    end
	end
        
        # Error raised when a communication callback is queueing another
        # communication callback
	class RecursiveCallbacksError < RuntimeError; end
        # Error raised when a callback has failed.
	class CallbackProcessingError < RuntimeError; end

    end
end
