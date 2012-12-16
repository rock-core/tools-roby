module Distributions
    class Gaussian
	attr_reader :mean, :dev
	def initialize(mean, dev)
	    @mean, @dev = mean, dev
	end
    end
end

module Roby
    # A TimeDistribution object describes the evolution of a 
    # value object w.r.t. time. Time can be described by absolute
    # values using Time objects or w.r.t. the plan by using 
    # EventGenerator objects
    class TimeDistribution
	attr_reader :info
	def initialize(info)
	    @info = info
	    @timepoints = Array.new
	end

	# Set the predicted value of the distribution at +event+
	def set_value(event, value)
	    @timepoints << [event, :set_value, value]
	end

	# Set a decay function which is valid from +event+
	def set_decay(event, decay)
	    @timepoints << [event, :set_decay, decay]
	end

	# Set the knowledge value for the distribution at +event+
	# For now, the only valid values are 0 (nothing known) 
	# and 1 (perfectly known)
	def set_knowledge(event, value = 1.0)
	    @timepoints << [event, :set_knowledge, value]
	end
    end

    class Task < PlanObject
        class << self
            define_inherited_enumerable(:needed_information) { Array.new }
            define_inherited_enumerable(:improved_information) { Array.new }
        end
	
	# This task is influenced by the information contained in +info+
	def self.needs(info); needed_information << info end
	def self.needs?(info); enum_for(:each_needed_information).any? { |i| info === i } end
	def needs?(info); self.model.needs?(info) end

	# This task will improve the information contained in +info+
	def self.improves(info); improved_information << info end
	def self.improves?(info); enum_for(:each_improved_information).any? { |i| info === i } end
	def improves?(info); self.model.improves?(info) end
    end
end

