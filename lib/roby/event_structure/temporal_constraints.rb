# Define Infinity
if !defined? Infinity
    Infinity = 1.0/0
end

module Roby
    class Plan
        # An EventStructure::EventDeadlines instance that is used by the
        # TemporalConstraints relation to maintain the set of event deadlines
        attribute(:emission_deadlines) { EventStructure::EventDeadlines.new }
    end

    module EventStructure
        # Class used to maintain the event deadlines
        class EventDeadlines
            attr_reader :deadlines

            def initialize
                @deadlines = Array.new
            end

            # Adds a deadline to the set
            def add(deadline, event, generator)
                deadlines << [deadline, event, generator]
                @deadlines = deadlines.sort_by(&:first)
            end

            # Remove the first deadline registered for +generator+
            def remove_deadline_for(generator, time)
                found = false
                deadlines.delete_if do |deadline, _, gen|
                    if found
                        false
                    else
                        found = (deadline > time && generator == gen)
                    end
                end
                found
            end

            # Returns the number of queued deadlines
            def size
                @deadlines.size
            end

            # Returns the set of deadlines that have been missed at
            # +current_time+. These deadlines get removed from the set.
            def missed_deadlines(current_time)
                result = []
                while !deadlines.empty? && deadlines.first[0] < current_time
                    result << deadlines.shift
                end
                result
            end
        end

        # Exception class used when an event has missed its deadline
        class MissedDeadlineError < LocalizedError
            # The event from which we deduced the deadline
            attr_reader :constraining_event
            # The time before which the failed generator should have emitted
            attr_reader :deadline

            def initialize(generator, constraining_event, deadline)
                super(generator)
                @constraining_event    = constraining_event
                @deadline = deadline
            end

            def pretty_print(pp)
                pp.text "#{failed_generator} missed the deadline of #{deadline}"
                pp.breakable
                pp.text "  required after the emission of #{constraining_event}"
            end
        end

        # Exception raised when an event gets emitted outside its specified
        # temporal constraints
        class TemporalConstraintViolation < LocalizedError
            attr_reader :parent_generator
            attr_reader :allowed_intervals
            def initialize(event, parent_generator, allowed_intervals)
                super(event)
                @parent_generator = parent_generator
                @allowed_intervals = allowed_intervals.dup
            end

            def pretty_print(pp)
                pp.text "Got "
                failed_event.pretty_print(pp)
                pp.text "It breaks the temporal constraint(s) #{allowed_intervals.map { |min, max| "[#{min}, #{max}]" }.join(" | ")} from"
                pp.nest(2) do
                    pp.breakable
                    parent_generator.pretty_print(pp)
                end
            end
        end

        # Exception raised when an event gets emitted outside its specified
        # temporal constraints
        class OccurenceConstraintViolation < LocalizedError
            attr_reader :parent_generator
            attr_reader :count
            attr_reader :allowed_interval
            attr_reader :since

            def initialize(event, parent_generator, count, allowed_interval, since)
                super(event)
                @parent_generator = parent_generator
                @count = count
                @allowed_interval = allowed_interval
                @since = since
            end

            def pretty_print(pp)
                pp.text "Got "
                failed_event.pretty_print(pp)
                pp.breakable
                pp.text "This does not satisfy the occurance constraint [#{allowed_interval[0]}, #{allowed_interval[1]}] from"
                pp.nest(2) do
                    pp.breakable
                    parent_generator.pretty_print(pp)
                end
                pp.breakable
                pp.text "which has been emitted #{count} times"
                if since
                    pp.text " since #{since}"
                end
            end
        end

        # A representation of a set of disjoint intervals, sorted in increasing
        # order
        class DisjointIntervalSet
            # A list of intervals as [min, max]. The list is sorted in increasing order
            attr_reader :intervals

            def initialize
                @intervals = Array.new
            end

            # Returns true if +value+ is included in one of the intervals
            def include?(value)
                candidate = intervals.
                    find { |min, max| max >= value }
                candidate && (candidate[0] <= value)
            end

            # Returns the lower and upper bound of the union of all intervals
            def boundaries
                [intervals.first[0], intervals.last[1]]
            end

            # Adds a new interval to the set, merging it with existing intervals
            # if needed
            #
            # Returns +self+
            def add(min, max)
                if intervals.empty?
                    intervals << [min, max]
                    return
                end

                new_list = Array.new
                while interval = intervals.shift
                    if interval[1] < min
                        new_list << interval
                    elsif interval[0] > min
                        if interval[0] > max
                            new_list << [min, max] << interval
                            break
                        else
                            new_list << [min, [max, interval[1]].max]
                        end
                        break
                    else
                        new_list << [interval[0], [max, interval[1]].max]
                        break
                    end
                end

                if intervals.empty? && new_list.last[1] < min
                    new_list << [min, max]

                elsif new_list.last[1] <= max
                    while interval = intervals.shift
                        last_interval = new_list.last

                        # It is guaranteed that interval[0] > last_interval[0].
                        # We therefore only need to check if interval[0] is
                        # included in last_interval
                        if interval[0] <= last_interval[1]
                            if last_interval[1] < interval[1]
                                last_interval[1] = interval[1]
                                break
                            end
                        else
                            new_list << interval
                            break
                        end
                    end
                end

                # We now know that the last interval in new_list has an upper
                # bound that comes from an already existing interval. We are
                # therefore sure that there are no overlaps.
                new_list.concat(intervals)
                @intervals = new_list
                self
            end
        end

        class TemporalConstraintSet < DisjointIntervalSet
            attr_reader :occurence_constraints

            def initialize
                super

                @occurence_constraints = {
                    true  => [0, Infinity],
                    false => [0, Infinity] }
            end

            def add_occurence_constraint(min, max, recurrent)
                existing = occurence_constraints[!!recurrent]
                if existing[0] < min
                    existing[0] = min
                end
                if existing[1] > max
                    existing[1] = max
                end
            end
        end

        # This relation maintains a network of temporal constraints between
        # events, that apply on the scheduling of these events
        #
        # If the a -> b edge exists in this graph, it specifies that
        # \c b can be scheduled if and only if \c a can be scheduled *regardless
        # of the existing temporal constraints that are due to \c b.
        #
        # As an example, let's set up a graph in which
        # * a task ta will be started after a task tb has started *but*
        # * all temporal constraints that apply on ta also apply on tb.
        #
        # The required edges are 
        #
        #   tb.success -> ta.start t=[0, Infinity], o=[1, Infinity] in TemporalConstraints
        #   ta.start -> tb.start in SchedulingConstraints
        #
        # The relation code takes care of maintaining the symmetric relationship
        relation :SchedulingConstraints,
            child_name: :forward_scheduling_constraint,
            parent_name: :backward_scheduling_constraint,
            dag: false,
            noinfo: true

        class SchedulingConstraints
            # The graph of tasks related to each other by their events
            attr_reader :task_graph

            def initialize(*args)
                super
                @task_graph = Relations::BidirectionalDirectedAdjacencyGraph.new
            end

            def add_edge(from, to, info)
                super

                if from.respond_to?(:task) && to.respond_to?(:task)
                    from_task, to_task = from.task, to.task
                    if from_task != to_task && !task_graph.has_edge?(from_task, to_task)
                        task_graph.add_edge(from_task, to_task, nil)
                    end
                end
            end

            def merge(graph)
                super
                task_graph.merge(graph.task_graph)
            end

            def replace(graph)
                super
                task_graph.replace(graph.task_graph)
            end

            def remove_vertex(event)
                super
                if event.respond_to?(:task)
                    task_graph.remove_vertex(event.task)
                end
            end

            def remove_edge(from, to)
                super
                if from.respond_to?(:task) && to.respond_to?(:task)
                    task_graph.remove_edge(from.task, to.task)
                end
            end

            def related_tasks?(ta, tb)
                task_graph.has_edge?(ta, tb)
            end

            def clear
                super
                task_graph.clear
            end

            module Extension
                def schedule_as(event)
                    event.add_forward_scheduling_constraint(self)
                end

                # True if this event is constrained by the TemporalConstraints
                # relation in any way
                def has_scheduling_constraints?
                    return true if has_temporal_constraints? 
                    each_backward_scheduling_constraint do |parent|
                        return true
                    end
                    false
                end
            end
        end

        # Module that implements shortcuts on tasks to use the scheduling
        # constraints
        module TaskSchedulingConstraints
            # Adds a constraint that ensures that the start event of +self+ is
            # scheduled as the start event of +task+
            def schedule_as(task)
                start_event.schedule_as(task.start_event)
            end
        end

        # This relation maintains a network of temporal constraints between
        # events.
        #
        # A relation A => B [min, max] specifies that, once the event A is
        # emitted, the event B should be emitted within a [min, max] amount of
        # time. Obviously, it is guaranteed that min > 0 and max > min
        #
        # The relation code takes care of maintaining the symmetric relationship
        relation :TemporalConstraints,
            child_name: :forward_temporal_constraint,
            parent_name: :backward_temporal_constraint,
            dag: false

        class TemporalConstraints
            module EventFiredHook
                # Overloaded to register deadlines that this event's emissions
                # define
                def fired(event)
                    super

                    # Verify that the event matches any running constraint
                    parent, intervals = find_failed_temporal_constraint(event.time)
                    if parent
                        plan.execution_engine.add_error TemporalConstraintViolation.new(event, parent, intervals.intervals)
                    end
                    parent, count, allowed_interval, since = find_failed_occurence_constraint(false)
                    if parent
                        plan.execution_engine.add_error OccurenceConstraintViolation.new(event, parent, count, allowed_interval, since)
                    end

                    deadlines = plan.emission_deadlines
                    # Remove the deadline that this emission fullfills (if any)
                    deadlines.remove_deadline_for(self, event.time)
                    # Add new deadlines
                    each_forward_temporal_constraint do |target, disjoint_set|
                        next if disjoint_set.intervals.empty?

                        max_diff = disjoint_set.boundaries[1]
                        is_fullfilled = target.history.any? do |target_event|
                            diff = event.time - target_event.time
                            break if diff > max_diff
                            disjoint_set.include?(diff)
                        end

                        if !is_fullfilled
                            deadlines.add(event.time + disjoint_set.boundaries[1], event, target)
                        end
                    end
                end
            end

            module Extension
                # Shortcut to specify that +self+ should be emitted after
                # +other_event+
                def should_emit_after(other_event, options = nil)
                    if options
                        options = Kernel.validate_options options,
                            min_t: nil, max_t: nil, recurrent: false
                        recurrent = options[:recurrent]
                    end
                    other_event.add_occurence_constraint(self, 1, Infinity, recurrent)
                    if options && (options[:min_t] || options[:max_t])
                        other_event.add_temporal_constraint(self,
                                options[:min_t] || 0, options[:max_t] || Infinity)
                    end
                end

                # True if this event is constrained by the TemporalConstraints
                # relation in any way
                def has_temporal_constraints?
                    each_backward_temporal_constraint do |parent|
                        return true
                    end
                    false
                end

                # Returns a [parent, intervals] pair that represents a temporal
                # constraint the given time fails to meet
                def find_failed_temporal_constraint(time)
                    each_backward_temporal_constraint do |parent|
                        if block_given?
                            next if !yield(parent)
                        end

                        disjoint_set = parent[self, TemporalConstraints]
                        next if disjoint_set.intervals.empty?

                        if disjoint_set.boundaries[0] < 0
                            # It might be fullfilled in the future
                            next
                        end

                        max_diff = disjoint_set.boundaries[1]
                        parent.history.each do |parent_event|
                            diff = time - parent_event.time
                            if diff > max_diff || !disjoint_set.include?(diff)
                                return parent, disjoint_set
                            end
                            disjoint_set.include?(diff)
                        end
                    end
                    nil
                end

                # Returns true if this event meets its temporal constraints
                def meets_temporal_constraints?(time, &block)
                    !find_failed_temporal_constraint(time, &block) &&
                        !find_failed_occurence_constraint(true, &block)
                end

                # Creates a temporal constraint between +self+ and +other_event+.
                # +min+ is the minimum time 
                def add_temporal_constraint(other_event, min, max)
                    if min > max
                        raise ArgumentError, "min should be lower than max (min == #{min} and max == #{max})"
                    end

                    if max < 0
                        return other_event.add_temporal_constraint(self, -max, -min)
                    elsif min < 0
                        set = TemporalConstraintSet.new
                        set.add(-max, -min)
                        other_event.add_forward_temporal_constraint(self, set)
                    end

                    set = TemporalConstraintSet.new
                    set.add(min, max)
                    add_forward_temporal_constraint(other_event, set)
                    set
                end

                # Adds a constraint on the allowed emission of +other_event+ based
                # on the existing emissions of +self+
                #
                # +min+ and +max+ specify the minimum (resp. maximum) of times
                # +self+ should be emitted before +other_event+ has the right to be
                # emitted.
                #
                # If +recurrent+ is true, then the min/max values are computed using
                # the emissions of +self+ since the last emission of +other_event+.
                # Otherwise, all emissions since the creation of +self+ are taken
                # into account.
                def add_occurence_constraint(other_event, min, max = Infinity, recurrent = false)
                    set = TemporalConstraintSet.new
                    set.add_occurence_constraint(min, max, recurrent)
                    add_forward_temporal_constraint(other_event, set)
                end

                def find_failed_occurence_constraint(next_event)
                    base_event = if next_event then last
                                 else history[-2]
                                 end
                    if base_event
                        base_time = base_event.time
                    end
                    each_backward_temporal_constraint do |parent|
                        if block_given?
                            next if !yield(parent)
                        end

                        constraints = parent[self, TemporalConstraints]
                        counts = { false => parent.history.size }
                        if base_time
                            negative_count = parent.history.inject(0) do |count, ev|
                                break(count) if ev.time > base_time
                                count + 1
                            end
                        else
                            negative_count = 0
                        end
                        counts[true] = counts[false] - negative_count
                        counts.each do |recurrent, count|
                            min_count, max_count = constraints.occurence_constraints[recurrent]
                            if count < min_count || count > max_count
                                if recurrent && base_time
                                    return [parent, parent.history.size, [min_count, max_count], base_time]
                                else
                                    return [parent, parent.history.size, [min_count, max_count]]
                                end
                            end
                        end
                    end
                    nil
                end

            end

            # Returns the DisjointIntervalSet that represent the merge of the
            # deadlines represented by +opt1+ and +opt2+
            def merge_info(parent, child, opt1, opt2)
                result = TemporalConstraintSet.new
                if opt1.intervals.size > opt2.intervals.size
                    result.intervals.concat(opt1.intervals)
                    for i in opt2.intervals
                        result.add(*i)
                    end
                else
                    result.intervals.concat(opt2.intervals)
                    for i in opt1.intervals
                        result.add(*i)
                    end
                end

                result.occurence_constraints.merge!(opt1.occurence_constraints)
                opt2.occurence_constraints.each do |recurrent, spec|
                    result.add_occurence_constraint(spec[0], spec[1], recurrent)
                end

                result
            end

            # Check the temporal constraint structure
            #
            # What it needs to do is check that events that *should* have been
            # emitted had been. The emission of events outside of allowed intervals
            # is already taken care of.
            #
            # Optimize by keeping the list of of maximum bounds at which an event
            # should be emitted.
            def check_structure(plan)
                deadlines = plan.emission_deadlines

                # Now look for the timeouts
                errors = []
                deadlines.missed_deadlines(Time.now).
                    each do |deadline, event, generator|
                        errors << MissedDeadlineError.new(generator, event, deadline)
                    end

                errors
            end
        end

        # Module defining shortcuts on tasks to use the temporal constraints
        module TaskTemporalConstraints
            # Ensures that this task is started after +task_or_event+ has
            # finished (if it is a task) or +task_or_event+ is emitted (if it is
            # an event)
            def should_start_after(task_or_event)
                case task_or_event
                when Roby::Task
                    start_event.should_emit_after(task_or_event.stop_event)
                when Roby::EventGenerator
                    start_event.should_emit_after(task_or_event)
                else
                    raise ArgumentError, "expected a task or an event generator, got #{task_or_event} of class #{task_or_event.class}"
                end
            end
        end
        Roby::EventGenerator.class_eval do
            prepend TemporalConstraints::EventFiredHook
        end
        Roby::Task.class_eval do
            prepend TaskSchedulingConstraints
            prepend TaskTemporalConstraints
        end
    end
end


