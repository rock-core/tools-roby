module Roby
    class Task
	# The mergeable? predicate checks if this task can be used
	# to fullfill the need of the given +model+ and +arguments+
	# It is false (never mergeable) by default
	def mergeable?(model, arguments); false end

	# Define a mergeable? predicate for this task model. If no
	# block if given, the task is mergeable if
	#   * the needed task model is an ancestor of this task
	#   * the task arguments are the same
	def self.mergeable(&block)
	    block ||= lambda do |model, arguments|
		(self.class < model || self.class == model) && arguments == self.arguments
	    end

	    class_eval do
		define_method(:__mergeable_p__, &block)
		define_method(:mergeable?) do |*args|
		    if args.size == 1
		        task = args.first
		        __mergeable_p__(task.class, task.arguments)
		    elsif args.size == 2
		        __mergeable_p__(*args)
		    end
		end
	    end
	end
    end
end

