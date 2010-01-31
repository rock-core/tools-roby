require 'test/unit'
require 'roby'
require 'roby/app'
require 'roby/test/common'
require 'roby/test/tasks/simple_task'

APP_DIR = File.expand_path('app', File.dirname(__FILE__))
require "#{APP_DIR}/tasks/services"
require "#{APP_DIR}/planners/main"

class TC_Subsystems < Test::Unit::TestCase
    include Roby::Test
    include Roby::Subsystems

    def setup
	super

        Roby.app.setup_global_singletons
        Roby.app.using :subsystems
	DRb.start_service
	Roby::State.pos = 0
	Roby::State.services do |s|
	    s.localization = 'test'
	    s.navigation   = 'test'
	end

        @plan = Roby.plan
        @engine = Roby.engine
    end

    def nav_loc
	tasks = plan.known_tasks.to_a
	assert_equal(2, tasks.size, tasks)
	if tasks.first.kind_of?(Services::Navigation)
	    tasks
	else tasks.reverse
	end
    end

    def test_initialize_plan
	start_with, ready = Application.initialize_plan(plan)

	nav, loc = nav_loc
	assert(plan.permanent?(nav))
	assert(plan.permanent?(loc))
	assert(nav.depends_on?(loc))

	assert_equal([loc.event(:start)], start_with.child_objects(EventStructure::Signal).to_a)

	signalled_events = loc.event(:ready).child_objects(EventStructure::Signal).to_value_set
        assert_equal 2, signalled_events.size
        assert_equal([nav.start_event, ready].to_value_set,
            loc.event(:ready).child_objects(EventStructure::Signal).to_value_set)

	assert_equal([nav.event(:start), loc.event(:ready)].to_set, ready.parent_objects(EventStructure::Signal).to_set)

    rescue Roby::Planning::NotFound
	STDERR.puts $!.full_message
	raise
    end

    def test_start_subsystems
	Roby.logger.level = Logger::FATAL
        Robot.logger.level = Logger::FATAL
        engine.run
        Subsystems::Application.run(Roby.app)

        Roby.execute do
            nav, loc = nav_loc
            assert(nav.running?)
            assert(loc.running?)
        end

	sleep(0.5)
	assert(Roby::State.pos > 0)
    end
end

