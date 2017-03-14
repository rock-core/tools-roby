module Roby
    module Coordination
        module Models
            # Object that is used to represent the context of an event context
            class Capture
                # The capture name
                #
                # Only used for debugging purposes
                #
                # @return [String]
                attr_accessor :name

                # Create a new capture object
                #
                # @param [#call] filter an object that is used to process the
                #   event's context. It is passed the context as-is (i.e. as an
                #   array) and should return the value that should be captured
                def initialize(filter = lambda { |event| event.context })
                    @filter = filter
                end

                # Filter the context through the filter object passed to
                # {#initialize}
                def filter(event)
                    @filter.call(event)
                end

                # Exception raised when trying to evaluate a capture whose
                # backing event has not yet happened
                class Unbound < RuntimeError
                    attr_reader :capture
                    def initialize(capture)
                        @capture = capture
                    end
                end

                # Evaluate the capture
                #
                # @param [Hash] variables the underlying coordination object's
                #   bound variables
                # @raise Unbound if the capture's backing event has not yet been
                #   emitted
                def evaluate(variables)
                    if variables.has_key?(self)
                        variables[self]
                    else
                        raise Unbound.new(self), "#{self} is not bound yet"
                    end
                end

                def to_s
                    "capture:#{name || '<unnamed>'}"
                end
            end
        end
    end
end

