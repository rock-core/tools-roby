require 'test/unit'
require 'roby'
require 'roby/app'
require 'roby/test/common'
require 'roby/test/tasks/simple_task'

APP_DIR = File.expand_path('app', File.dirname(__FILE__))
require "#{APP_DIR}/tasks/services"
require "#{APP_DIR}/planners/main"
Roby.app.using :subsystems

State = Roby::State
Robot = Roby

class TC_Subsystems < Test::Unit::TestCase
    include Roby::Test
    include Roby::Subsystems

    def setup
	super
	DRb.start_service
	State.pos = 0
	State.services do |s|
	    s.localization = 'test'
	    s.navigation   = 'test'
	end
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
	start_with, ready = Application.initialize_plan

	nav, loc = nav_loc
	assert(plan.permanent?(nav))
	assert(plan.permanent?(loc))
	assert(nav.realized_by?(loc))

	assert_equal([loc.event(:start)], start_with.child_objects(EventStructure::Signal).to_a)

	and_gen = loc.event(:ready).child_objects(EventStructure::Signal).to_a.first
	assert_equal([nav.event(:start)], and_gen.child_objects(EventStructure::Signal).to_a)

	assert_equal([nav.event(:start), loc.event(:ready)].to_set, ready.parent_objects(EventStructure::Signal).to_set)

    rescue Roby::Planning::NotFound
	STDERR.puts $!.full_message
	raise
    end

    def test_start_subsystems
	Roby.logger.level = Logger::FATAL
	Roby.control.run :detach => true

	Application.run(Roby.app) { }
	nav, loc = nav_loc
	assert(nav.running?)
	assert(loc.running?)

	sleep(0.5)
	assert(State.pos > 0)
    end
end

