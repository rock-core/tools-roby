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
        assert_nothing_raised { Roby::Genom::Mockup::SetIndex }
	assert_equal("Roby::Genom::Mockup::Start", Roby::Genom::Mockup::Start.name)

	task = Roby::Genom::Mockup.start!
	assert_equal("Roby::Genom::Mockup::Start", task.model.name)
    end

    def test_runner_task
        Genom.connect do
            Genom::GenomModule('mockup')

            runner = Genom::Mockup.runner!
	    assert_equal("Roby::Genom::Mockup::Runner", runner.model.name)
	    
	    runner.start!
	    assert_event( runner.event(:start) )

	    runner.stop!
	    assert_event( runner.event(:stop) )
        end
    end
            
    def test_event_handling
        ::Genom.connect do
            Genom::GenomModule('mockup')

            runner = Genom::Mockup.runner!
	    runner.start!
	    assert_event( runner.event(:start) )

            start_activity
        end
    end

    def test_control_to_exec
	mod = Genom::GenomModule('mockup')

	control_task = mod.set_index!(5)
	exec_task    = mod.control_to_exec(:set_index!, 5)
	assert_equal(Genom::Mockup::Runner, control_task.class.execution_agent)
	assert_equal(Genom::Mockup::Runner, exec_task.class.execution_agent)
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

