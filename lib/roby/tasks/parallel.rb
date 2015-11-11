module Roby::Tasks
    class Parallel < TaskAggregator
	def name
	    @name || @tasks.map { |t| t.name }.join("|")
	end

	attr_reader :children_success
        def initialize(arguments = {})
	    super

	    @children_success = Roby::AndGenerator.new
	    @children_success.forward_to event(:success)
        end

        def child_of(task = nil)
	    return super() unless task

	    task = task.new unless task.kind_of?(Roby::Task)
	    @tasks.each do |t| 
		task.depends_on t
		task.signals(:start, t, :start)
	    end
	    task.event(:success).emit_on children_success

	    delete

	    task
        end

        def <<(task)
	    raise "trying to change a running parallel task" if running?
            @tasks << task

	    signals(:start, task, :start)
	    depends_on task
	    children_success << task.event(:success)

            self
        end

        def to_parallel; self end
    end
end
