# frozen_string_literal: true

module Roby
    module Queries
        class MatcherBase
            # Returns true if calling #filter with a task set and a relevant
            # index will return the exact query result or not
            def indexed_query?
                false
            end

            # Enumerates all tasks of +plan+ which match this TaskMatcher object
            #
            # It is O(N). You should prefer use Query which uses the plan's task
            # indexes, thus leading to O(1) in simple cases.
            def each(plan)
                return enum_for(__method__, plan) unless block_given?

                plan.each_task do |t|
                    yield(t) if self === t
                end
                self
            end

            # Negates this predicate
            #
            # The returned task matcher will yield tasks that are *not* matched by
            # +self+
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
                    method_name = name.to_s.gsub(/\?$/, '')
                    class_eval <<~PREDICATE_CODE, __FILE__, __LINE__ + 1
                        def #{method_name}
                            if neg_predicates.include?(:#{name})
                                raise ArgumentError,
                                      "trying to match (#{name} & !#{name})"
                            end
                            predicates << :#{name}
                            self
                        end
                        def not_#{method_name}
                            if predicates.include?(:#{name})
                                raise ArgumentError,
                                      "trying to match (#{name} & !#{name})"
                            end
                            neg_predicates << :#{name}
                            self
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
