require 'test_config'
require 'test/unit'
require 'roby/adapters/genom'
require 'genom/runner'

class TC_Genom < Test::Unit::TestCase
    include Roby
    def test_def
        model = Genom::GenomModule('mockup')
        assert_nothing_raised { Roby::Genom::Mockup }
        assert_nothing_raised { Roby::Genom::Mockup::Start }
        assert_raises(NameError) { Roby::Genom::Mockup::SetIndex }
    end

    def setup
        @env = ::Genom::Runner.environment || ::Genom::Runner.h2 
    end

    def teardown
        ::Genom.connect do
            @env.stop_modules('mockup')
        end
        sleep(1)
    end

    def test_module_task
        ::Genom.connect do
            Genom::GenomModule('mockup')
            start_task  = Genom::Mockup.start

            Genom::Mockup::Runner.new.start!
            start_activity
        end
    end
            

    def test_event_handling
        ::Genom.connect do
            mod = Genom::GenomModule('mockup')
            @env.start_modules('mockup')
            start_activity
        end
    end

    def start_activity
        task = Genom::Mockup.start
        task.start!
        activity = task.activity
        
        assert_doesnt_timeout(2) { 
            while !task.running?
                $stderr.puts "waiting for task to start"
                Roby.process_events
            end
        }
        
        activity.abort.wait
        assert(!task.finished?)
        assert_doesnt_timeout(2) {
            while !task.finished?
                $stderr.puts "waiting for task to end"
                Roby.process_events
            end
        }

        assert(task.finished?)
    end
end

