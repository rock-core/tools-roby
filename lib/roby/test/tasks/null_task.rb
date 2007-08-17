module Roby
    module Test
	class NullTask < Roby::Task
	    forward :start => :stop
	end
    end
end

