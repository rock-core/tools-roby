module Roby
    module Actions
        module Models
            # Definition of the metamodel for Actions::FaultResponseTable
            module FaultResponseTable
                include Models::Interface

                # The set of defined fault handlers
                #
                # @return [FaultHandler]
                inherited_attribute('fault_handler', 'fault_handlers') { Array.new }

                def find_all_matching_handlers(exception)
                    each_fault_handler do |h|
                        h.execution_exception_matcher === exception
                    end
                end

                def on_fault(exception_matcher, &block)
                    exception_matcher = exception_matcher.to_execution_exception_matcher
                    @current_description = FaultHandlingAction.new
                    action_model, handler =
                        action_coordination(nil, Actions::FaultHandler, &block)
                    action_model.fault_handler_model = handler
                    handler.execution_exception_matcher = exception_matcher
                    handler.action = action_model
                    fault_handlers << handler
                    handler
                end

                def method_missing(m, *args, &block)
                    if Queries::ExecutionExceptionMatcher.method_defined?(m)
                        matcher = Queries::ExecutionExceptionMatcher.new
                        matcher.send(m, *args, &block)
                        matcher
                    else super
                    end
                end
            end
        end
    end
end

