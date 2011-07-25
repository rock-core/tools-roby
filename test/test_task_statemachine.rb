$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))

include Roby::TaskStateHelper 

class TestTask < Roby::Task
    refine_running_state do
        event :one do 
            transition [:running, :zero] => :one
        end

        event :two do
            transition [:one] => :two
        end

        event :three do
            transition [:two] => :three
        end

        event :reset do
            transition all => :zero
        end
    end
end

class SecondTestTask < Roby::Task
    refine_running_state :namespace => 'test' do
        event :firstly do 
            transition [:running] => :first
        end 

        event :secondly do
            transition [:first] => :second
        end
    end
end

class DerivedTask < TestTask
    refine_running_state do
        event :four do
	    transition [:three] => :four
	end
    end
end

class TC_TaskStateMachine < Test::Unit::TestCase
    include Roby::Test
    include Roby::Test::Assertions

    def setup
        super
        Roby.app.filter_backtraces = false
        @testTask = TestTask.new
    end


    def test_responds_to_state_machine
        assert( @testTask.respond_to?("state_machine") )
    end

    def test_responds_to_state_machine_status
        assert( @testTask.state_machine.status )
    end
      
    def test_has_initial_state_running 
        assert( @testTask.state_machine.status == 'running')
    end

    def test_has_all_states
        all_states = @testTask.state_machine.all_states
        check_states = [ :zero, :one, :two, :three ]
        check_states.each do |state|
            assert( all_states.index(state) >= 0 )
        end
    end

    def test_check_multiple_instances
        oneTask = TestTask.new
        twoTask = TestTask.new
        scndTask = SecondTestTask.new
	
        assert( TestTask.namespace == nil)
        eval("oneTask.state_machine.one#{TestTask.namespace}!")
        assert(oneTask.state_machine.status == 'one')
        
        assert(twoTask.state_machine.status == 'running')
        assert(scndTask.state_machine.status == 'running')
        
        assert( SecondTestTask.namespace == "test")
        eval("scndTask.state_machine.firstly_test!") #_#{SecondTestTask.namespace}!")
        assert(scndTask.state_machine.status == 'first')
    end

    def test_inheritance
	derivedTask = DerivedTask.new
	assert(derivedTask.state_machine.proxy.respond_to?(:one))
	assert(derivedTask.state_machine.proxy.respond_to?(:two))
	assert(derivedTask.state_machine.proxy.respond_to?(:three))
	assert(derivedTask.state_machine.proxy.respond_to?(:reset))
	assert(derivedTask.state_machine.proxy.respond_to?(:four))
      
        event = [ :one, :two, :three, :four, :reset ] 
	begin
	    event.each do |event|
		eval("derivedTask.state_machine.#{event}!")
            end
	rescue Exception => e
	    assert (false, "Calling event '#{event} failed")
	end
    end
end
