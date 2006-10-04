require 'roby/task'
require 'roby/relations/hierarchy'

module Roby::TaskAggregator
    module Operations
        def +(task)
            # !!!! + is NOT commutative
            if task.respond_to?(:to_sequence)
                task.to_sequence.unshift self
            elsif task.null?
                self
            elsif self.null?
                task
            else
                Sequence.new << self << task
            end
        end
        def |(task)
            if task.respond_to?(:to_parallel)
                task.to_parallel | self
            elsif self.null?
                task
            elsif task.null?
                self
            else
                Parallel.new << self << task
            end
        end
            
    end

    class TaskAggregator < Roby::Task
	event(:start,	:command => true)

	attr_reader :tasks
	def initialize; @tasks = Array.new; super end
	def each_task(&iterator)
	    yield(self)
	    tasks.each(&iterator) 
	end
    end

    class Sequence < TaskAggregator
        include Operations

	def name
	    @tasks.map { |t| t.name }.join("+")
	end

	def connect_start(task)
	    if old = @tasks.first
		event(:start).remove_signal old.event(:start)
		task.on(:success, old, :start)
	    end

	    event(:start).on task.event(:start)
	end

	def connect_stop(task)
	    if old = @tasks.last
		old.on(:success, task, :start)
		old.event(:success).remove_forwarding event(:success)
	    end
	    event(:success).emit_on task.event(:success)
	end
	private :connect_stop, :connect_start

        def unshift(task)
            raise "trying to do Sequence#unshift on a running or finished sequence" if (running? || finished?)
	    connect_start(task)
	    connect_stop(task) if @tasks.empty?

            @tasks.unshift(task)
	    realized_by task
	    self
        end

        def <<(task)
	    raise "trying to do Sequence#<< on a finished sequence" if finished?
	    connect_start(task) if @tasks.empty?
	    connect_stop(task)
	    
	    @tasks << task
	    realized_by task
	    self
        end

        def to_sequence; self end
        def +(task)
            self << task unless task.null?
            self
        end
    end

    class Parallel < TaskAggregator
        include Operations

	def name
	    @tasks.map { |t| t.name }.join("|")
	end

	attr_reader :success
        def initialize
	    super

	    @success = Roby::AndGenerator.new
	    event(:success).emit_on @success
        end

        def <<(task)
	    raise "trying to change a running parallel task" if running?
            @tasks << task

	    on(:start, task, :start)
	    realized_by task
	    success << task.event(:success)

            self
        end

        def to_parallel; self end
        def |(task)
            self << task unless task.null?
            self
        end
    end
end

module Roby
    class Task
        include TaskAggregator::Operations
    end

end

