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
	def forward(event, op = nil, *args)
	    event = case event
		    when :start;    start_event
		    when :stop;	    stop_event
		    else; raise ArgumentError, "no such event #{event}"
		    end

	    if op
		event.send(op, *args)
	    else
		event
	    end
	end

	def event(event); forward(event) end
	def on(event, *args); forward(event, :on, *args) end

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
            task.on(:stop, @tasks.first, :start) unless @tasks.empty?
	    @start_event.delete(@tasks.first.event(:start))

            @tasks.unshift(task)
	    @start_event << task.event(:start)
        end

        def <<(task)
	    unless @tasks.empty?
		@tasks.last.on(:stop, task, :start)
		@tasks.last.event(:stop).remove_signal @stop_event
	    end

            @tasks << task 
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
	    if aggregator.start_event.controlable?
		def self.start(context)
		    aggregator.start_event.call(context)
		end
	    end
	    singleton_class.event(:start)

	    if aggregator.stop_event.controlable?
		def self.stop(context)
		    aggregator.stop_event.call(context)
		end
	    end
	    singleton_class.event(:stop)

	    aggregator.each_task do |child|
		realized_by child
	    end

	    super()
	end
    end

end

module Roby
    class Task
        include TaskAggregator::Operations
    end

end

