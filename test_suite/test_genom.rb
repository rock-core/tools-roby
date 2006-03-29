require 'test_config'
require 'test/unit'
require 'roby/adapters/genom'
require 'genom/runner'

class TC_Genom < Test::Unit::TestCase
    include Roby

    def env; Genom::Runner.environment end
    def setup
        Genom::Runner.environment || Genom::Runner.h2 
    end
    def teardown
	Genom.connect { env.stop_modules('mockup') }
    end

    def test_def
        model = Genom::GenomModule('mockup')
        assert_nothing_raised { Roby::Genom::Mockup }
        assert_nothing_raised { Roby::Genom::Mockup::Start }
        assert_raises(NameError) { Roby::Genom::Mockup::SetIndex }
    end

    def test_runner_task
        Genom.connect do
            Genom::GenomModule('mockup')

            runner = Genom::Mockup.runner!
	    runner.start!
	    assert_event( runner.event(:start) )

	    runner.stop!
	    assert_event( runner.event(:stop) )
        end
    end
            

    def test_event_handling
        ::Genom.connect do
            mod = Genom::GenomModule('mockup', :start => true)
            start_activity
        end
    end

    def start_activity
        task = Genom::Mockup.start!
	assert_equal(Genom::Mockup::Runner, task.class.execution_agent)
	
        task.start!
        activity = task.activity
        
	assert_event( task.event(:start) )
        
        activity.abort.wait
        assert(!task.finished?)
	assert_event( task.event(:stop) )
        assert(task.finished?)
    end
end

