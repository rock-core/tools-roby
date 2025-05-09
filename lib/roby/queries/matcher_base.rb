# frozen_string_literal: true

module Roby
    module Queries
        class MatcherBase
            # Returns true if calling #filter with a task set and a relevant
            # index will return the exact query result or not
            def indexed_query?
                false
            end

            def each(plan)
                Roby.warn_deprecated "MatcherBase#each is deprecated, "\
                                     "use #each_in_plan instead"

                each_in_plan(plan)
            end

            # Enumerates all tasks of +plan+ which match this TaskMatcher object
            def each_in_plan(plan)
                return enum_for(__method__, plan) unless block_given?

                plan.each_task do |t|
                    yield(t) if self === t
                end
                self
            end

            # Finds all matching objects in plan and returns them as an Array
            #
            # It is essentially equivalent to each_in_plan(plan).to_a, but might
            # be optimized in some cases
            def to_a(plan)
                each_in_plan(plan).to_a
            end

            # Finds all matching objects in plan and returns them as a Set
            #
            # It is essentially equivalent to each_in_plan(plan).to_set, but is
            # optimized in indexed resolutions where a Set is already available
            def to_set(plan)
                each_in_plan(plan).to_set
            end

            def reset
                Roby.warn_deprecated "Matcher#reset is a no-op now, matchers "\
                                     "don't cache their results anymore"
            end

            def negate
                NotMatcher.new(self)
            end

            # AND-combination of two predicates
            #
            # The returned task matcher will yield tasks that are matched by both
            # predicates.
            def &(other)
                AndMatcher.new(self, other)
            end

            # OR-combination of two predicates
            #
            # The returned task matcher will yield tasks that match either one
            # predicate or the other.
            def |(other)
                OrMatcher.new(self, other)
            end

            # Set of predicates that should be true for the object
            # @return [Array<Symbol>]
            attr_reader :predicates

            # Set of predicats that should be false for the object
            #
            # The predicates are predicate method names (e.g. 'executable' for
            # #executable?)
            #
            # @return [Array<Symbol>]
            attr_reader :neg_predicates

            # @api private
            #
            # Add the given predicate to the set of predicates that must match
            def add_predicate(predicate)
                if @neg_predicates.include?(predicate)
                    raise ArgumentError, "trying to match (#{predicate} & !#{predicate})"
                end

                @predicates << predicate unless @predicates.include?(predicate)
                self
            end

            # @api private
            #
            # Add the given predicate to the set of predicates that must match
            def add_neg_predicate(predicate)
                if @predicates.include?(predicate)
                    raise ArgumentError, "trying to match (#{predicate} & !#{predicate})"
                end

                @neg_predicates << predicate unless @neg_predicates.include?(predicate)
                self
            end

            class << self
                def declare_class_methods(*names) # :nodoc:
                    names.each do |name|
                        unless method_defined?(name)
                            raise "no instance method #{name} on #{self}"
                        end

                        singleton_class.send(:define_method, name) do |*args|
                            new.send(name, *args)
                        end
                    end
                end

                def match_predicate(name)
                    method_name = name.to_s.gsub(/\?$/, "")
                    class_eval <<~PREDICATE_CODE, __FILE__, __LINE__ + 1
                        def #{method_name}
                            add_predicate(:#{name})
                        end
                        def not_#{method_name}
                            add_neg_predicate(:#{name})
                        end
                    PREDICATE_CODE
                    declare_class_methods(method_name, "not_#{method_name}")
                end

                # For each name in +names+, define a #name and a #not_name method.
                # If the first is called, the matcher will match only tasks whose
                # #name? method returns true.  If the second is called, the
                # opposite will be done.
                def match_predicates(*names)
                    names.each do |name|
                        match_predicate(name)
                    end
                end
            end

            # The {#match} method is used to convert any object to the
            # corresponding Query object. For instance, Models::TaskEvent#match
            # returns the corresponding TaskEventGeneratorMatcher.
            #
            # For matchers, it returns self
            def match
                self
            end

            # Describe a failed match in a human-readable way
            #
            # It is meant to help debugging in tests
            #
            # @return [nil,String]
            def describe_failed_match(exception); end
        end
    end
end
