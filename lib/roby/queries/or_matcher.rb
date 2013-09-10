module Roby
    module Queries

    # Combines multiple task matching predicates through a OR boolean operator.
    # I.e. it will match if any of the underlying predicates match.
    class OrMatcher < MatcherBase
        # Create a new OrMatcher object combining the given predicates.
	def initialize(*ops)
	    @ops = ops 
	end

        # Overload of TaskMatcher#filter
	def filter(task_set, task_index)
	    result = ValueSet.new
	    for child in @ops
		result.merge child.filter(task_set, task_index)
	    end
	    result
	end

        # Add a new predicate to the combination
	def <<(op); @ops << op end

	def ===(task)
	    @ops.any? { |op| op === task }
	end

        # An intermediate representation of OrMatcher objects suitable to
        # be sent to our peers.
	class DRoby
            attr_reader :ops
            def initialize(ops)
                @ops = ops
            end
            def proxy(peer)
                OrMatcher.new(*ops.proxy(peer))
            end
	end
	
        # Returns an intermediate representation of +self+ suitable to be sent
        # to the +dest+ peer.
	def droby_dump(dest)
            DRoby.new(@ops.droby_dump(dest))
	end
    end

    end
end
