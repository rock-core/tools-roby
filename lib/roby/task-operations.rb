require 'roby/task'
require 'roby/relations/hierarchy'

module Roby::TaskAggregator
    module Operations
        def +(task)
            # !!!! + is NOT commutative
            if task.respond_to?(:to_sequence)
                task.to_sequence.unshift self
            else
                Sequence.new << self << task
            end
        end
        def |(task)
            if task.respond_to?(:to_parallel)
                task.to_parallel | self
            else
                Parallel.new << self << task
            end
        end
            
    end

    class Sequence < Roby::Task
        include Operations
        def initialize
            @tasks = Array.new 
            super
        end

        def start(context)
            class << self; private :unshift end
            @tasks.first.
                on(:start) { emit :start }.
                start!
        end
        event :start

        def stop(context)
            current = @tasks.find { |t| t.running? }
            current.stop!
        end
        event :stop
        
        def unshift(task)
            raise "trying to do Sequence#unshift on a running sequence" if running?
            task.on(:stop, @tasks.first, :start) unless @tasks.empty?
            @tasks.unshift(task)
            added(task)
        end
        def <<(task)
            @tasks.last.on(:stop, task, :start) unless @tasks.empty?
            @tasks << task 
            added(task)
        end

        def to_sequence; self end
        def +(task); self << task end
        
    private
        def added(task)
            self.realized_by(task)
            task.on(:stop) do |event|
                if event.task == @tasks.last
                    emit(:stop, event.context) 
                end
            end
            
            self
        end
    end

    class Parallel < Roby::Task
        include Operations
        def initialize
            @tasks = Set.new 
            @stop_aggregator = Roby::AndEvent.new do |event|
                emit :stop, event
            end
            super
        end

        def start(context)
            emit :start
            @tasks.each { |task| task.start! }
        end
        event :start

        def stop(context)
            @tasks.each { |task| task.stop! }
        end
        event :stop

        def <<(task)
            @tasks << task
            @stop_aggregator << task.event(:stop)
            self
        end

        def to_parallel; self end
        def |(task); self << task end
    end
end

module Roby
    class Task
        include TaskAggregator::Operations
    end
end

