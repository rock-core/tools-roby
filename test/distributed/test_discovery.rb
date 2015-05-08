require 'roby/distributed'
require 'roby/test/self'

module Roby
    module Distributed
        describe Discovery do
            attr_reader :discovery
            before do
                @discovery = Discovery.new
            end

            def server_port
                23810
            end

            describe "#start and #wait" do
                it "calls the #neighbours method asynchronously" do
                    stub = Class.new do
                        attr_reader :th
                        def neighbours
                            @th = Thread.current
                            Array.new
                        end
                    end.new
                    discovery.add stub
                    discovery.start
                    discovery.wait
                    refute_equal Thread.current, stub.th
                end
                it "does not restart work that is not finished" do
                    cv, sync = ConditionVariable.new, Mutex.new
                    stub = Class.new do
                        define_method(:neighbours) do
                            sync.synchronize do
                                cv.broadcast
                                cv.wait(sync)
                            end
                        end
                    end.new

                    work = discovery.add(stub)
                    flexmock(stub).should_receive(:neighbours).once.pass_thru
                    flexmock(work).should_receive(:spawn).once.pass_thru

                    # Here, we have to wait for the work to be running
                    sync.synchronize do
                        discovery.start
                        cv.wait(sync)
                    end
                    discovery.start
                    cv.broadcast
                end
            end

            describe "#wait" do
                it "returns the new neighbours list" do
                    stub = flexmock(neighbours: [1, 2])
                    discovery.add stub
                    discovery.start
                    assert_equal [1,2], discovery.wait
                end
            end

            describe "a successful discovery" do
                it "updates the last_known_neighbours to the newly returned value" do
                    stub = flexmock
                    stub.should_receive(:neighbours).and_return([1, 2])
                    w = discovery.add(stub)
                    w.last_known_neighbours = [2,3]
                    discovery.start
                    assert_equal [1,2], discovery.wait, "#{w.future.reason}"
                    assert_equal [1,2], w.last_known_neighbours
                end
            end

            describe "a failed discovery" do
                it "resets the neighbour list" do
                    stub = flexmock
                    stub.should_receive(:neighbours).and_raise(ArgumentError)
                    w = discovery.add(flexmock)
                    w.last_known_neighbours = [1,2]
                    inhibit_fatal_messages do
                        discovery.start
                        assert_equal [], discovery.wait
                    end
                    assert_equal [], w.last_known_neighbours
                end
            end

            describe "#neighbours" do
                it "returns empty at initialization" do
                    discovery.add(flexmock)
                    assert_equal [], discovery.neighbours
                end
                it "concatenates the currently-known neighboours" do
                    w = discovery.add(flexmock)
                    flexmock(w).should_receive(:last_known_neighbours).and_return { [1,2] }
                    w = discovery.add(flexmock)
                    flexmock(w).should_receive(:last_known_neighbours).and_return { [3,4] }
                    assert_equal [1,2,3,4], discovery.neighbours
                end
            end
            
            describe "#listen_to_tuplespace" do
                attr_reader :tuplespace

                before do
                    @tuplespace = Rinda::TupleSpace.new
                end

                describe "connection and discovery" do
                    before do
                        tuplespace.write([:droby, 'host', 10])
                    end

                    it "connects to a tuplespace given by its URI" do
                        tuplespace_server = DRb::DRbServer.new("druby://localhost:#{server_port}", tuplespace)
                        discovery.listen_to_tuplespace("localhost:#{server_port}")
                        discovery.start
                        assert_equal [Neighbour.new('host', 10)], discovery.wait
                        tuplespace_server.stop_service
                    end
                    it "connects to a local tuplespace object" do
                        discovery.listen_to_tuplespace(tuplespace)
                        discovery.start
                        assert_equal [Neighbour.new('host', 10)], discovery.wait
                    end
                    it "connects to a tuplespace given by its DRbObject" do
                        drb_tuplespace = DRb::DRbObject.new(tuplespace)
                        discovery.listen_to_tuplespace(drb_tuplespace)
                        discovery.start
                        assert_equal [Neighbour.new('host', 10)], discovery.wait
                    end
                end
            end

            describe "#listen_to_ring" do
                attr_reader :publisher

                before do
                    @publisher = RingDiscovery.new(port: server_port, timeout: 0.1)
                    publisher.register(Neighbour.new('host', 10))
                end
                after do
                    publisher.deregister
                end
                it "reports reachable ring servers" do
                    discovery.listen_to_ring('127.0.0.1', port: server_port, timeout: 0.1)
                    discovery.start
                    assert_equal [Neighbour.new('host', 10)], discovery.wait
                end
            end
        end
    end
end

