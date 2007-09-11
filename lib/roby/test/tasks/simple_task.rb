require 'roby/task'

module Roby
    module Test
	class SimpleTask < Roby::Task
	    argument :id

	    def initialize(arguments = {})
		arguments = { :id => object_id.to_s }.merge(arguments)
		super(arguments)
	    end

	    event :start, :command => true
	    event :success, :command => true, :terminal => true
	    terminates
	end
    end
end

