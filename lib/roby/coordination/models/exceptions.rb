module Roby
    module Coordination
        module Models
            # Base class for model validation errors
            class CoordinationModelError < Exception; end

            # Exception thrown when using a non-root event in a context where
            # only root events are allowed
            class NotRootEvent < CoordinationModelError; end

            # Exception raised in state machine definitions when a state is used
            # in a transition, that cannot be reached in the first place
            class UnreachableStateUsed < RuntimeError
                # The set of unreachable states
                attr_reader :states

                def initialize(states)
                    @states = states
                end

                def pretty_print(pp)
                    pp.text "#{states.size} states are unreachable but used in transitions anyways"
                    pp.nest(2) do
                        pp.seplist(states) do |s|
                            pp.breakable
                            s.pretty_print(pp)
                        end
                    end
                end
            end

            # Exception thrown when a toplevel state was expected but a
            # dependency was given
            class NotToplevelState < CoordinationModelError; end

            # Exception thrown when using an event in a context where it is not
            # active
            class EventNotActiveInState < CoordinationModelError; end
        end
    end
end

