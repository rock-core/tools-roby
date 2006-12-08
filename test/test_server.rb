require 'test_config'

require 'roby/control'

class TC_TestDrbServer < Test::Unit::TestCase
    include RobyTestCommon

    URI="druby://localhost:9000"
    def test_server_spawning
        # Start the event loop within a subprocess
        reader, writer = IO.pipe
        @server_process = fork do
            Roby.logger.level = Logger::WARN
            $stderr.puts "Starting the Roby server"
            Roby::Control.instance.run(:drb => URI) { 
                $stderr.puts "Roby server started on #{URI}"
                writer.write "OK"
            }
        end
        DRb.start_service
        $stderr.puts "Waiting for the Roby server"
        reader.read 2
        @client = Roby::Client.new("druby://localhost:9000")
        $stderr.puts "... connected"

        @client.quit
        DRb.stop_service
        assert_doesnt_timeout(10) { 
	    begin
		Process.waitpid(@server_process) 
	    rescue Errno::ECHILD
	    end
	}
    end
end

