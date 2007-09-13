require 'roby'
require 'roby/test/common'
require 'flexmock'
require 'genom/runner'

Roby.app.plugin_dir File.expand_path('../..', File.dirname(__FILE__))
Roby.app.reset
Roby.app.using 'genom'

BASE_TEST_DIR = File.expand_path(File.dirname(__FILE__))
path=ENV['PATH'].split(':')
pkg_config_path=(ENV['PKG_CONFIG_PATH'] || "").split(':')

Dir.glob("#{BASE_TEST_DIR}/prefix.*") do |p|
    path << "#{p}/bin"
    pkg_config_path << "#{p}/lib/pkgconfig"
end
ENV['PATH'] = path.join(':')
ENV['PKG_CONFIG_PATH'] = pkg_config_path.join(':')

class TC_Genom < Test::Unit::TestCase
    include Roby::Test
    Runner = ::Genom::Runner

    def env; Runner.environment end
    def setup
	Roby.control.run :detach => true
	super

        Runner.environment || Runner.h2 
    end
    def teardown
	Genom.connect do
	    env.stop_module('mockup')
	    env.stop_module('init_test')
	end
	super
    end

    def test_def
        model = Genom::GenomModule('mockup')
        assert_nothing_raised { Roby::Genom::Mockup }
        assert_nothing_raised { Roby::Genom::Mockup::Start }
        assert_nothing_raised { Roby::Genom::Mockup::SetIndexControl }
	assert_equal("Roby::Genom::Mockup::Start", Roby::Genom::Mockup::Start.name)

	task = Roby::Genom::Mockup.start!
	# assert_equal("#<Roby::Genom::Mockup::Start!0x#{task.address.to_s(16)}>", task.model.to_s)
    end

    def test_argument_checking
	model = Genom::GenomModule('mockup')
	assert_raises(ArgumentError) { model::SetIndexControl.new(:new_value => 10, :bla => 20) }
	assert_raises(TypeError) { model::SetIndexControl.new(:new_value => "bla") }
    end

    def start_runner(mod)
	runner = mod.runner!
	assert_event(runner.event(:start)) do
	    plan.discover(runner)
	    runner.start!
	end

	runner
    end
    def stop_runner(task, event = :stop)
	assert_event(task.event(event)) do
	    if block_given?
		yield
	    else
		plan.auto(task)
	    end
	end
    end

    def assert_event(event)
	did_once = false
	while true
	    result = Roby.execute do
		unless did_once
		    yield if block_given?
		    did_once = true
		end

		if event.happened?
		    true
		elsif event.unreachable?
		    raise
		end
	    end
	    return if result
	    Roby.wait_one_cycle
	end
    end

    def test_runner_task
        Genom.connect do
            mod = Genom::GenomModule('mockup')
	    
	    runner = start_runner(mod)
	    assert(runner.running?)
	    assert(runner.event(:ready).happened?)

	    stop_runner(runner)

	    runner = start_runner(mod)
	    stop_runner(runner) do
		Process.kill 'INT', Genom::Mockup.genom_module.pid
	    end
        end
    end

    def test_init
	mod = Genom::GenomModule('init_test')
	assert_raises(ArgumentError) do
	    Genom.connect { mod.runner! }
	end
	
	# Create the ::init singleton method
	FlexMock.use do |mock|
	    mod.singleton_class.class_eval do
		define_method(:init) do
		    mock.runner_running(mod.genom_module.roby_runner_task.running?)
		    mock.init_called
		    init!(42)
		end
	    end

	    mod::Init.on(:start) { mock.init_started }
	    mod::Init.on(:success) { mock.init_success }

	    mock.should_receive(:runner_running).with(true).once.ordered
	    mock.should_receive(:init_called).once.ordered
	    mock.should_receive(:init_started).once.ordered
	    mock.should_receive(:init_success).once.ordered
	    Genom.connect do
		runner = start_runner(mod)
		assert(runner.event(:ready).happened?)

		mod.genom_module.poster(:index).wait
		assert_equal(42, mod.genom_module.index!.update_period)
	    end
	end
    end
            
    def test_interruption_handling
        ::Genom.connect do
            mod = Genom::GenomModule('mockup')
	    start_runner(mod)

	    plan.permanent(task = Genom::Mockup.start!)
	    assert_equal(Genom::Mockup::Runner, task.class.execution_agent)
	    
	    assert_event( task.event(:start) ) do
		task.start!
	    end
	    assert(!task.finished?)

	    assert_event( task.event(:interrupted) ) do
		task.stop!
	    end
	    assert(task.finished?)
        end
    end

    def test_control_to_exec
	mod = Genom::GenomModule('mockup')
	original_model = mod::SetIndexControl
	mod.control_to_exec(:SetIndex) do
	    original_model.genom_module.set_index!(0).wait
	    emit :failed
	end

	assert_same(original_model, mod::SetIndexControl)
	assert_not_same(original_model, mod::SetIndex)

	plan.permanent(task = mod.set_index!(5))
	assert_kind_of(mod::SetIndex, task)

	Roby.logger.level = Logger::DEBUG
	::Genom.connect do
	    assert_event(task.event(:start)) do
		task.start!
	    end
	    sleep(0.5)
	    assert_equal(5, mod.genom_module.index!.value)

	    assert_event(task.event(:stop)) do
		task.stop!
	    end
	    sleep(0.5)
	    assert_equal(0, mod.genom_module.index!.value)
	end
    end

    def test_needs_precondition
	mod = Genom::GenomModule('mockup')
	Roby::Genom::Mockup::Start.class_eval do
	    needs :SetIndexControl
	end

	GC.start

	::Genom.connect do
	    plan.discover(runner = Genom::Mockup.runner!)
	    runner.start!
	    assert_event( runner.event(:ready) )

	    plan.permanent(task = Genom::Mockup.start!)
	    assert_raises(Roby::EventPreconditionFailed) { task.start!(nil) }
	end
    end
end

