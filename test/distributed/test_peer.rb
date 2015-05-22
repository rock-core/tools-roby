require 'roby/test/self'
require 'roby/distributed'

module Roby
    module Distributed
        describe Peer do
            describe "connection" do
                def local_server_port
                    23810
                end
                def remote_server_port
                    23811
                end

                attr_reader :remote_space
                attr_reader :local_space
                attr_reader :peer, :neighbour

                before do
                    @remote_space = create_connection_space(remote_server_port)
                    @local_space  = create_connection_space(local_server_port)
                    @peer   = Peer.new(local_space, 'test', RemoteID.new('localhost', remote_server_port))
                end

                it "connects to a ConnectionSpace object" do
                    thread = peer.connect
                    process_events_until { !remote_space.peers.empty? }
                    thread.join
                    local_space.execution_engine.process_events
                    assert_equal :connected, peer.connection_state
                    assert peer.connected?
                end

                it "handles concurrent connection requests" do
                    remote_peer   = Peer.new(remote_space, 'test', RemoteID.new('localhost', local_server_port))
                    remote_thread = remote_peer.connect
                    local_thread  = peer.connect
                    process_events_until { !remote_peer.connecting? && !peer.connecting? }
                    local_thread.join
                    remote_thread.join
                    remote_space.execution_engine.process_events
                    local_space.execution_engine.process_events
                    assert_equal :connected, remote_peer.connection_state
                    assert_equal :connected, peer.connection_state
                end

                it "handles losing links" do
                    peer.connect
                    process_events_until { peer.connected? }
                    _, remote_peer = remote_space.peers.first
                    assert remote_peer.connected?
                    peer.socket.close
                    process_events_until { !remote_peer.link_alive? }
                    process_events_until { peer.connected? && peer.link_alive? && remote_peer.connected? && remote_peer.link_alive? }
                end
            end
        end
    end
end
