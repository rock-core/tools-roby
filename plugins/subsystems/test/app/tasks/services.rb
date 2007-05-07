require 'roby/test/tasks/simple_task'
SimpleTask = Roby::Test::SimpleTask

module Services
    class Navigation < SimpleTask; end
    class Localization < SimpleTask
	event :ready, :command => true
	on :start => :ready

	def update_localization(state)
	    state.pos += 1
	end
    end
end

