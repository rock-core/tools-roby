module Roby::Tasks
    # Creates an ordered sequence of tasks.
    #
    # Tasks added to this aggregator are started one after the other. Task(i+1)
    # is started when Task(i) has finished successfully. The Sequence finishes
    # successfully when the last task finished.
    class Sequence < TaskAggregator
        def name # :nodoc:
            @name || @tasks.map { |t| t.name }.join("+")
        end

        # Quite often, a sequence is meant to implement a higher-level
        # functionality. In this case, it is better to not use a Sequence task
        # at all, but instead create the sequence as dependency of a high-level
        # task instance.
        #
        # #to_task transfers the underlying sequence to the task given as
        # argument. If +task+ is a task model instead of a task instance, it
        # first creates a new instance of this model and returns it.
        #
        # For instance:
        #   
        #   seq = (Sequence.new <<
        #       GoTo.new(target: a) <<
        #       Pickup.new(object: b) <<
        #       GoTo.new(target: c)
        #
        #   mission = GetObject.new(object: b)
        #   seq.child_of(mission)
        #
        def child_of(task = nil)
            return super() unless task
            task = task.new unless task.kind_of?(Roby::Task)
            @tasks.each { |t| task.depends_on t }

            task.start_event.signals @tasks.first.start_event
            @tasks.last.success_event.forward_to task.success_event

            delete

            task
        end

        def connect_start(task) # :nodoc:
            if old = @tasks.first
                start_event.remove_signal old.start_event
                task.success_event.signals old.start_event
            end

            start_event.signals task.start_event
        end

        def connect_stop(task) # :nodoc:
            if old = @tasks.last
                old.success_event.signals task.start_event
                old.success_event.remove_forwarding success_event
            end
            task.success_event.forward_to success_event
        end
        private :connect_stop, :connect_start

        # Adds +task+ at the beginning of the sequence
        def unshift(task)
            raise "trying to do Sequence#unshift on a running or finished sequence" if (running? || finished?)
            connect_start(task)
            connect_stop(task) if @tasks.empty?

            @tasks.unshift(task)
            depends_on task
            self
        end

        # Adds +task+ at the end of the sequence
        def <<(task)
            raise "trying to do Sequence#<< on a finished sequence" if finished?
            connect_start(task) if @tasks.empty?
            connect_stop(task)
            
            @tasks << task
            depends_on task
            self
        end

        def to_sequence # :nodoc:
            self
        end
    end
end
