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

    class TaskAggregator
	attr_reader :start_event, :stop_event
	def forward(event, op = nil, *args, &block)
	    event = case event
		    when :start;    start_event
		    when :stop;	    stop_event
		    else; raise ArgumentError, "no such event #{event}"
		    end

	    if op
		event.send(op, *args, &block)
	    else
		event
	    end
	end

	def event(event); forward(event) end
	def on(event, *args, &block); forward(event, :on, *args, &block) end

	attr_reader :tasks
	def each_task(&iterator); tasks.each(&iterator) end
	def running?;  tasks.any? { |t| t.running? } end
	def finished?; stop_event.happened? end

	def to_task
	    AggregatorTask.new(self.freeze)
	end
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
	attr_reader :tasks
        def initialize
            super

            @tasks = Set.new 
	    @start_event = Roby::ForwarderGenerator.new
	    @stop_event	= Roby::AndGenerator.new
        end

        def <<(task)
            @tasks << task
	    start_event << task.event(:start)
            stop_event << task.event(:stop)
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

