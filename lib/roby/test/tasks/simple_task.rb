require 'roby/task'

module Roby
    module Test
	class SimpleTask < Roby::Task
	    event :start, :command => true
	    event :success, :command => true, :terminal => true
	    terminates
	end
    end
end

