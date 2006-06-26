module Roby
    class Task
	# Define a fullfills? predicate for this task model.
	#
	# The fullfills? predicate checks if this task can be used
	# to fullfill the need of the given +model+ and +arguments+
	# The default is to check if
	#   * the needed task model is an ancestor of this task
	#   * the task arguments are the same
	def self.fullfills(&block)
	    raise ArgumentError, "no block given" unless block

	    class_eval do
		define_method(:__fullfills_p__, &block)
		define_method(:fullfills?) do |*args|
		    if args.size == 1
		        task = args.first
		        __fullfills_p__(task.class, task.arguments || {})
		    elsif args.size == 2
		        __fullfills_p__(*args)
		    end
		end
	    end
	end

	fullfills do |model, arguments|
	    self_args = self.arguments || {}
	    args = arguments || {}

	    (self.class < model || self.class == model) && self_args.slice(*args.keys) == args
	end

    end
end

