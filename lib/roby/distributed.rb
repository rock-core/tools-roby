require 'roby'
require 'stringio'

require 'roby/distributed/base'
require 'roby/distributed/protocol'
require 'roby/distributed/exceptions'

require 'roby/distributed/neighbour'
require 'roby/distributed/remote_id'
require 'roby/distributed/connection_request'
require 'roby/distributed/connection_task'
require 'roby/distributed/peer'
require 'roby/distributed/peer_server'
require 'roby/distributed/remote_object_manager'
require 'roby/distributed/peer_read_state'
require 'roby/distributed/connection_space'
require 'roby/distributed/call_spec'

require 'roby/distributed/discovery'
require 'roby/distributed/ring_server'
require 'roby/distributed/ring_discovery'
require 'roby/distributed/central_discovery'

require 'roby/distributed/notifications'
require 'roby/distributed/distributed_object'
require 'roby/distributed/transaction'

# == Communication protocol (and code namespace structure)
# == Getting remote objects
# There is actually two ways to get a remote object
# * the object has been explicitely subscribed to by calling Peer#subscribe
# * the object has been sent to us because it is linked to an object we own
#   or an object we are subscribed to
#
# In the first case, the object must be referenced in the first place. It can
# have been sent to us as a query result (see Query), or because it has been
# involved in a distributed transaction. In the second case, it is either us
# which have added the relation, or the remote peer. If it is us, we should
# have subscribed to the object, added the relation, and then we may
# unsubscribe to the object.
#
# We forget about a remote object when Plan#garbage_collect removes it.
#
# == Subscription management
# The pDB gets updated about all objects it is subscribed to.
module Roby::Distributed
end


