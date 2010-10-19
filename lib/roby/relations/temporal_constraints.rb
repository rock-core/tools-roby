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
                pp.text "#{failed_event} has been emitted outside its specified temporal constraints"
                pp.breakable
                pp.text "  #{parent_generator}: #{allowed_intervals.map { |min, max| "[#{min}, #{max}]" }.join(" | ")}"
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

        # This relation maintains a network of temporal constraints between
        # events.
        #
        # A relation A => B [min, max] specifies that, once the event A is
        # emitted, the event B should be emitted within a [min, max] amount of
        # time. Obviously, it is guaranteed that min > 0 and max > min
        #
        # The relation code takes care of maintaining the symmetric relationship
        relation :TemporalConstraints,
            :child_name => :forward_temporal_constraint,
            :parent_name => :backward_temporal_constraint,
            :dag => false do

            # Creates a temporal constraint between +self+ and +other_event+.
            # +min+ is the minimum time 
            def add_temporal_constraint(other_event, min, max)
                if min > max
                    raise ArgumentError, "min should be lower than max (min == #{min} and max == #{max})"
                end

                if max < 0
                    return other_event.add_temporal_constraint(self, -max, -min)
                elsif min < 0
                    other_event.do_add_temporal_constraint(self, -max, -min)
                end
                do_add_temporal_constraint(other_event, min, max)
            end

            def do_add_temporal_constraint(other_event, min, max)
                # Check if there are already constraints from self to
                # other_event. If it is the case, simply update the disjoint set
                if TemporalConstraints.linked?(self, other_event)
                    self[other_event, EventStructure::TemporalConstraints].add(min, max)
                else
                    set = DisjointIntervalSet.new
                    set.add(min, max)
                    add_forward_temporal_constraint(other_event, set)
                end
            end

            # Overloaded to register deadlines that this event's emissions
            # define
            def fired(event)
                super if defined? super

                # Verify that the event matches any running constraint
                each_backward_temporal_constraint do |parent|
                    disjoint_set = parent[self, TemporalConstraints]
                    if disjoint_set.boundaries[0] < 0
                        # It might be fullfilled in the future
                        next
                    end

                    max_diff = disjoint_set.boundaries[1]
                    is_fullfilled = parent.history.any? do |parent_event|
                        diff = event.time - parent_event.time
                        break if diff > max_diff
                        disjoint_set.include?(diff)
                    end
                    if !is_fullfilled
                        raise TemporalConstraintViolation.new(event, parent, disjoint_set.intervals)
                    end
                end

                deadlines = plan.emission_deadlines
                # Remove the deadline that this emission fullfills (if any)
                deadlines.remove_deadline_for(self, event.time)
                # Add new deadlines
                each_forward_temporal_constraint do |target, disjoint_set|
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

        # Returns the DisjointIntervalSet that represent the merge of the
        # deadlines represented by +opt1+ and +opt2+
        def TemporalConstraints.merge_info(parent, child, opt1, opt2)
            result = DisjointIntervalSet.new
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
        def TemporalConstraints.check_structure(plan)
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
end


