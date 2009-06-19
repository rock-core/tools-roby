module Roby
    module TaskOperations
        def +(task)
            # !!!! + is NOT commutative
            if task.null?
                self
            elsif self.null?
                task
            else
                Sequence.new << self << task
            end
        end
        def |(task)
            if self.null?
                task
            elsif task.null?
                self
            else
                Parallel.new << self << task
            end
        end
            
    end

    class Task
        include TaskOperations
    end

    class TaskAggregator < Roby::Task
	terminates
	event(:start, :command => true)

	attr_reader :tasks
	def initialize(arguments = {}); @tasks = Array.new; super end
	def each_task(&iterator)
	    yield(self)
	    tasks.each(&iterator) 
	end
	def empty?; tasks.empty? end

	def delete
	    @name  = self.name
	    @tasks = nil
	    if plan
		plan.remove_object(self)
	    else
		clear_relations
		freeze 
	    end
	end
    end

    class Sequence < TaskAggregator
	def name
	    @name || @tasks.map { |t| t.name }.join("+")
	end

	def to_task(task = nil)
	    return super() unless task
	    task = task.new unless task.kind_of?(Roby::Task)
	    @tasks.each { |t| task.depends_on t }

	    task.signals(:start, @tasks.first, :start)
	    @tasks.last.forward_to(:success, task, :success)

	    delete

	    task
	end
        def child_of(task = nil)
            to_task(task)
        end

	def connect_start(task)
	    if old = @tasks.first
		event(:start).remove_signal old.event(:start)
		task.signals(:success, old, :start)
	    end

	    event(:start).signals task.event(:start)
	end

	def connect_stop(task)
	    if old = @tasks.last
		old.signals(:success, task, :start)
		old.event(:success).remove_forwarding event(:success)
	    end
	    task.forward_to(:success, self, :success)
	end
	private :connect_stop, :connect_start

        def unshift(task)
            raise "trying to do Sequence#unshift on a running or finished sequence" if (running? || finished?)
	    connect_start(task)
	    connect_stop(task) if @tasks.empty?

            @tasks.unshift(task)
	    depends_on task
	    self
        end

        def <<(task)
	    raise "trying to do Sequence#<< on a finished sequence" if finished?
	    connect_start(task) if @tasks.empty?
	    connect_stop(task)
	    
	    @tasks << task
	    depends_on task
	    self
        end

        def to_sequence; self end
    end

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
            to_task(task)
        end
	def to_task(task = nil)
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

    class Group < Roby::Task
	def initialize(*tasks)
	    super()
	    if tasks.empty? || tasks.first.kind_of?(Hash)
		return
	    end

	    success = AndGenerator.new
	    tasks.each do |task|
		depends_on task
		task.event(:success).signals success
	    end
	    success.forward_to event(:success)
	end

	event :start do
	    children.each do |child|
		if child.pending? && child.event(:start).root?
		    child.start!
		end
	    end
	    emit :start
	end
	terminates
    end
end

