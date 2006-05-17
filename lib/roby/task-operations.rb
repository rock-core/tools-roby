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
	
	def connect_start(task)
	    if old = @tasks.first
		@start_event.delete(old.event(:start))
		task.on(:stop, old, :start)
	    end
	    @start_event << task.event(:start)
	end

	def connect_stop(task)
	    if old = @tasks.last
		old.on(:stop, task, :start)
		old.event(:stop).remove_signal @stop_event
	    end
	    task.event(:stop).on @stop_event
	end

        def unshift(task)
            raise "trying to do Sequence#unshift on a running sequence" if running?
	    connect_stop(task) if @tasks.empty?
	    connect_start(task)
            @tasks.unshift(task)
	    self
        end

        def <<(task)
	    connect_start(task) if @tasks.empty?
	    connect_stop(task)
	    @tasks << task
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
		event(:start, :command => true)
		event(:stop, :command => true)
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

