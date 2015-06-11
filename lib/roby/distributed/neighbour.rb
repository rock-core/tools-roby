module Roby
    module Distributed
        # A neighbour is a [name, remote_id] tuple, where +name+ is the name of
        # the neighbour and +remote_id+ the RemoteID which describes the remote
        # ConnectionSpace, used to connect to it.
	class Neighbour
	    attr_reader :name, :remote_id
	    def initialize(name, remote_id)
		@name, @remote_id = name, remote_id
	    end

	    def connect; Peer.initiate_connection(ConnectionSpace.state, peer) end
	    def ==(other)
		other.kind_of?(Neighbour) &&
		    (remote_id == other.remote_id)
	    end
	    def to_s; "#<Neighbour:#{name} #{remote_id}>" end
	    def eql?(other); other == self end
	end
    end
end

