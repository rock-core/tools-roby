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
        assert_doesnt_timeout(1) { Control.instance.run }
        assert(start_node.finished?)
	assert(if_node.finished?)
    end

    def check_garbage_collection(selections)
	selections.each do |kind, tasks|
	    set = Control.instance.instance_eval { eval "@#{kind}" }
	    assert_equal(tasks.to_set, set)
	end
    end

    def test_garbage_collect
	plan = Plan.new
	control = Control.instance
	control.insert(plan)

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
	[t1, t3, t4].each { |t| control.mission(t) }

	control.garbage_mark
	check_garbage_collection :garbage => Set.new, :garbage_can => Set.new

	control.discard(t3)
	assert(!control.useful?(t3))
	control.garbage_mark
	check_garbage_collection :garbage => [t3], :garbage_can => Set.new

	t1.start!(nil)
	t1.failed!(nil)
	assert(t1.finished?)
	control.garbage_mark
	assert(!control.useful?(t2))
	check_garbage_collection :garbage => [t2, t3], :garbage_can => Set.new

	#t2.start!(nil)
	control.discard(t4)
	control.garbage_mark
	check_garbage_collection :garbage => [t4, t2, t3], :garbage_can => Set.new

	assert(control.useful?(t5))
	assert(t4.pending? && control.marked?(t4))
	assert_nothing_raised { control.garbage_collect } # t3 should not be terminated since it is not running
	assert(t4.dead?)
	check_garbage_collection :garbage_can => [t4, t3, t2]
	#check_garbage_collection :garbage => [t5]
    end
end


