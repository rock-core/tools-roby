module Roby
    class DecisionControl
    end

    class << self
	attr_reader :decision_control
    end

    @decision_control = DecisionControl.new
end

