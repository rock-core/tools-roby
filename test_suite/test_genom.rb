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
	Genom.connect do
	    env.stop_module('mockup')
	    env.stop_module('init_test')
	end
    end

    def test_def
        model = Genom::GenomModule('mockup')
        assert_nothing_raised { Roby::Genom::Mockup }
        assert_nothing_raised { Roby::Genom::Mockup::Start }
        assert_nothing_raised { Roby::Genom::Mockup::SetIndex }
	assert_equal("Roby::Genom::Mockup::Start", Roby::Genom::Mockup::Start.name)

	task = Roby::Genom::Mockup.start!
	# assert_equal("#<Roby::Genom::Mockup::Start!0x#{task.address.to_s(16)}>", task.model.to_s)
    end

    def test_argument_checking
	model = Genom::GenomModule('mockup')
	assert_raises(ArgumentError) { model::SetIndex.new(10, 20) }
	assert_raises(TypeError) { model::SetIndex.new("bla") }
    end

    def test_runner_task
        Genom.connect do
            Genom::GenomModule('mockup')

            runner = Genom::Mockup.runner!
	    # assert_equal("#<Roby::Genom::Mockup::Runner!0x#{runner.address.to_s(16)}>", runner.model.name)
	    
	    runner.start!
	    assert_event( runner.event(:start) )
	    assert_event( runner.event(:ready) )

	    runner.stop!
	    assert_event( runner.event(:stop) )

	    runner = Genom::Mockup.runner!
	    runner.start!
	    assert_event( runner.event(:start) )
	    Process.kill 'INT', Genom::Mockup.genom_module.pid
	    assert_event( runner.event(:failed) )
        end
    end

    def test_init
	mod = Genom::GenomModule('init_test')

	assert_raises(ArgumentError) do
	    Genom.connect do
		mod.runner!
	    end
	end
	
	init_period = nil
	mod.class_eval do
	    singleton_class.class_eval do
		define_method(:init) do
		    init_period = init!(42) 
		end
	    end
	end

	did_start = false
	mod::Init.on(:start) { did_start = true }
	Genom.connect do
	    runner = mod.runner!
	    runner.start!

	    assert( init_period )
	    assert( Genom.running.include?(init_period) )
	    assert( init_period.event(:start).pending? )

	    assert_event( init_period.event(:success) )
	    assert_event( runner.event(:ready) )

	    mod.genom_module.poster(:index).wait
	    assert_equal(42, mod.genom_module.index.update_period)
	end
	assert(did_start)
    end
            
    def test_event_handling
        ::Genom.connect do
            Genom::GenomModule('mockup')

            runner = Genom::Mockup.runner!
	    runner.start!
	    assert_event( runner.event(:ready) )

	    task = Genom::Mockup.start!
	    assert_equal(Genom::Mockup::Runner, task.class.execution_agent)
	    
	    task.start!
	    assert_event( task.event(:start) )
	    
	    task.stop!
	    assert(!task.finished?)
	    assert_event( task.event(:stop) )
	    assert(task.finished?)
        end
    end

    def test_control_to_exec
	mod = Genom::GenomModule('mockup')

	control_task = mod.set_index!(5)
	exec_task    = mod.control_to_exec(:set_index!, 5)
	assert_equal(Genom::Mockup::Runner, control_task.class.execution_agent)
	assert_equal(Genom::Mockup::Runner, exec_task.class.execution_agent)
    end
end

