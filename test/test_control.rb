require 'test_config'
require 'roby/control'
require 'roby/plan'
require 'mockups/tasks'

class TC_Control < Test::Unit::TestCase 
    include Roby

    def test_event_loop
        start_node = EmptyTask.new
        next_event = [ start_node, :start ]
        if_node    = ChoiceTask.new
        start_node.on(:stop) { next_event = [if_node, :start] }
	if_node.on(:stop) { raise Interrupt }
            
        Control.event_processing << lambda do 
            next unless next_event
            task, event = *next_event
            next_event = nil
            task.event(event).call(nil)
        end
        assert_doesnt_timeout(1) { Control.run }
        assert(start_node.finished?)
	assert(if_node.finished?)
    end

    def check_garbage_collection(selections)
	selections.each do |kind, tasks|
	    set = Control.instance.instance_eval { eval "@#{kind}" }
	    assert_equal(tasks, set)
	end
    end
    def bump_cycle_index
	Control.instance.instance_eval { @cycle_index += 1 }
    end

    def test_garbage_collect
	plan = Plan.new
	Control.insert(plan)

	task_model = Class.new(Task) do
	    event(:start, :command => true)
	    event(:failed, :command => true, :terminal => true)
	    def stop(context)
	    end
	end

	t1, t2, t3, t4, t5 = (1..5).map do
	   t = task_model.new
	   plan << t
	   t
	end
	t1.add_child t2
	t4.add_child t5
	[t1, t3, t4].each { |t| Control.protect(t) }

	Control.garbage_mark
	check_garbage_collection :garbage => {}, :garbage_can => Set.new

	Control.unprotect(t3)
	assert(!Control.useful?(t3))
	Control.garbage_mark
	check_garbage_collection :garbage => { t3 => 0 }, :garbage_can => Set.new
	bump_cycle_index

	t1.start!(nil)
	t1.failed!(nil)
	assert(t1.finished?)
	Control.garbage_mark
	assert(!Control.useful?(t2))
	check_garbage_collection :garbage => { t2 => 1, t3 => 0 }, :garbage_can => Set.new
	bump_cycle_index

	#t2.start!(nil)
	Control.unprotect(t4)
	Control.garbage_mark
	check_garbage_collection :garbage => { t4 => 2, t2 => 1, t3 => 0 }, :garbage_can => Set.new
	bump_cycle_index

	assert(Control.useful?(t5))
	assert(t4.pending? && Control.marked?(t4))
	assert_nothing_raised { Control.garbage_collect } # t3 should not be terminated since it is not running
	assert(t4.dead?)
	check_garbage_collection :garbage_can => [t4, t3, t2].to_set
	check_garbage_collection :garbage => { t5 => 3 }
    end
end


