
require 'test_config'
require 'test/unit'

require 'roby'
require 'roby/plan'

class TC_Plan < Test::Unit::TestCase
    include Roby
    def test_base
	plan = Plan.new
	task_model = Class.new(Task) do 
	    event :start
	    event :stop, :command => true
	end

	t1, t2, t3 = 3.enum_for(:times).map { task_model.new }
	t1.realized_by t2
	t2.on(:start, t3, :stop)

	plan.insert(t1)
	tasks = plan.tasks
	assert( tasks.include?(t1) )
	assert( tasks.include?(t2) )
	assert( tasks.include?(t3) )
    end
end

