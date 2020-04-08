# frozen_string_literal: true

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
                def initialize(filter = lambda(&:context))
                    @filter = filter
                end

                # Filter the context through the filter object passed to
                # {#initialize}
                def filter(state_machine, event)
                    CaptureEvaluationContext.new(state_machine)
                        .instance_exec(event, &@filter)
                end

                class CaptureEvaluationContext < Object
                    def initialize(state_machine)
                        @state_machine = state_machine
                    end

                    def respond_to_missing?(m, include_private)
                        @state_machine.model.has_argument?(m) || super
                    end

                    def method_missing(m, *args)
                        if @state_machine.arguments.has_key?(m)
                            if args.empty?
                                return @state_machine.arguments[m]
                            else
                                raise ArgumentError, "expected zero argument to #{m}, got #{args.size}"
                            end
                        elsif @state_machine.model.has_argument?(m)
                            raise ArgumentError, "#{m} is not set"
                        end
                        super
                    end
                end

                # Exception raised when trying to evaluate a capture whose
                # backing event has not yet happened
                class Unbound < RuntimeError
                    attr_reader :capture
                    def initialize(capture)
                        @capture = capture
                    end
                end

                def evaluate_delayed_argument(task)
                    throw :no_value
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
