$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'
require 'roby/relations/temporal_constraints'
require 'roby/schedulers/temporal'
require 'flexmock'

class TC_Schedulers_Temporal < Test::Unit::TestCase
    include Roby::Test

    def test_scheduling_time
        scheduler = Roby::Schedulers::Temporal.new(true, plan)

        t1, t2, t3 = prepare_plan :add => 3, :model => Tasks::Simple
        e1 = t1.start_event
        e2 = t2.start_event
        e3 = t3.start_event
        t1.executable = false

        e2.should_emit_after(e1, :min_t => 5, :max_t => 10)
        t2.depends_on t3

        FlexMock.use(Time) do |time|
            current_time = Time.now
            time.should_receive(:now).and_return { current_time }

            scheduler.initial_events
            assert !t1.running?
            assert !t2.running?
            assert !t3.running?

            t1.executable = true
            scheduler.initial_events
            assert t1.running?
            assert !t2.running?
            assert !t3.running?

            current_time += 6
            scheduler.initial_events
            assert t1.running?
            assert t2.running?
            assert !t3.running?
            scheduler.initial_events
            assert t1.running?
            assert t2.running?
            assert t3.running?
        end
    end
end



