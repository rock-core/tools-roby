TOP_SRC_DIR = File.expand_path( File.join(File.dirname(__FILE__), '..') )
$LOAD_PATH.unshift TOP_SRC_DIR
$LOAD_PATH.unshift File.join(TOP_SRC_DIR, 'test')

require 'roby/distributed/connection_space'

TEST_SIZE=20
BASE_PERIOD=0.5

include Roby
include Roby::Distributed
BROADCAST = (1..10).map { |i| "127.0.0.#{i}" }

def test(discovery_period)
    start_r, start_w= IO.pipe
    quit_r, quit_w = IO.pipe
    remote_pid = fork do
        start_r.close
        quit_w.close

        DRb.start_service
        Distributed.state = ConnectionSpace.new period: discovery_period, ring_discovery: true, ring_broadcast: BROADCAST
        Distributed.publish bind: '127.0.0.2'

        start_w.write('OK')
        quit_r.read(2)
        Distributed.unpublish
    end
    start_w.close
    quit_r.close
    start_r.read(2)

    DRb.start_service
    Distributed.state = ConnectionSpace.new period: discovery_period, ring_discovery: true, ring_broadcast: BROADCAST
    Distributed.publish bind: '127.0.0.1'

    Distributed.state.start_neighbour_discovery
    Distributed.state.wait_discovery
    raise unless Distributed.neighbours.find { |n| n.name == "#{Socket.gethostname}-#{remote_pid}" }

ensure
    Distributed.unpublish
    start_r.close
    quit_w.write('OK')
    Process.waitpid(remote_pid)
end

period = BASE_PERIOD
error_count = 0
while (error_count.to_f / TEST_SIZE) < 0.1
    error_count = 0
    STDERR.print "#{period}"
    (0..TEST_SIZE).each do |i|
        begin
            test(period)
        rescue Exception => e
            if e.class != RuntimeError
                STDERR.puts e.message
            end
            error_count += 1
        end
        STDERR.print "\r#{period} (#{i}|#{error_count}|#{TEST_SIZE})"
    end
    STDERR.puts
    period /= 2
end

