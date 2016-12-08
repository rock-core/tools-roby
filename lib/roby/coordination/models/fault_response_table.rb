module Roby
    module Coordination
        module Models
            # Definition of the metamodel for Coordination::FaultResponseTable
            module FaultResponseTable
                include Roby::Actions::Models::Interface
                include Arguments

                # The set of defined fault handlers
                #
                # @return [FaultHandler]
                inherited_attribute('fault_handler', 'fault_handlers') { Array.new }

                def find_all_matching_handlers(exception)
                    each_fault_handler.find_all do |h|
                        h.execution_exception_matcher === exception
                    end
                end

                # Representation of a fault handler at the interface level
                class Action < Roby::Actions::Models::Action
                    attr_reader :fault_response_table_model

                    # The fault handler model itself
                    def fault_handler_model
                        coordination_model
                    end

                    # The common interface to set the fault handler
                    attr_accessor :coordination_model

                    def initialize(fault_response_table_model)
                        super()
                        @fault_response_table_model = fault_response_table_model
                    end
                end

                def on_fault(exception_matcher, &block)
                    exception_matcher = exception_matcher.to_execution_exception_matcher
                    action_model = Action.new(self)
                    each_argument do |_, arg|
                        action_model.required_arg(arg.name)
                    end
                    action_model, handler =
                        create_coordination_action(action_model, Coordination::FaultHandler, &block)
                    handler.execution_exception_matcher(exception_matcher)
                    fault_handlers << handler
                    handler
                end

                def each_task
                    return enum_for(:each_task) if !block_given?
                    super
                    each_fault_handler do |handler|
                        if task = handler.replacement
                            yield(task)
                        end
                    end
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

