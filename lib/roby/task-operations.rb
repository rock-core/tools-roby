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
	def each_task(&iterator); tasks.each(&iterator) end
    end

    class Sequence < TaskAggregator
        include Operations

	attr_reader :tasks
        def initialize
            @tasks = Array.new 
	    @start_event = Roby::ForwarderGenerator.new
	    @stop_event  = Roby::EventGenerator.new(true)
            super
        end

        def unshift(task)
            raise "trying to do Sequence#unshift on a running sequence" if running?
	    unless @tasks.empty?
		task.on(:stop, @tasks.first, :start)
		@start_event.delete(@tasks.first.event(:start))
	    end

	    @start_event << task.event(:start)
            @tasks.unshift(task)
        end

        def <<(task)
	    if @tasks.empty?
		unshift(task)
	    else
		@tasks.last.on(:stop, task, :start)
		@tasks.last.event(:stop).remove_signal @stop_event
		@tasks << task 
	    end

	    task.event(:stop).on @stop_event
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

    class AggregatorTask < Roby::Task
	def initialize(aggregator)
	    singleton_class.class_eval do
		if aggregator.start_event.controlable?
		    define_method(:start, &aggregator.start_event.method(:call))
		    event(:start)
		end

		if aggregator.stop_event.controlable?
		    define_method(:stop, &aggregator.stop_event.method(:call))
		    event(:stop)
		end
	    end

	    aggregator.each_task do |child|
		realized_by child
	    end

	    super()
	    event(:start).on aggregator.start_event
	    aggregator.stop_event.on event(:stop)
	end
    end

end

module Roby
    class Task
        include TaskAggregator::Operations
    end

end

