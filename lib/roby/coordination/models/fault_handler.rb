module Roby
    module Coordination
        module Models
            # Definition of a single fault handler in a FaultResponseTable
            module FaultHandler
                include Actions
                include Script

                # @return [FaultResponseTable] the table this handler is part of
                def fault_response_table; action_interface end
                # @return [Queries::ExecutionExceptionMatcher] the object
                #   defining for which faults this handler should be activated
                inherited_single_value_attribute(:execution_exception_matcher) { Queries.none }
                # @return [Integer] this handler's priority
                inherited_single_value_attribute(:priority) { 0 }
                # @return [:missions,:actions,:origin] the fault response
                #   location
                inherited_single_value_attribute(:response_location) { :actions }
                inherited_single_value_attribute(:__try_again) { false }
                # @return [Boolean] if true, the last action of the response
                #   will be to retry whichever action/missions/tasks have been
                #   interrupted by the fault
                def try_again?; !!__try_again end
                # @return [#instanciate] an object that allows to create the
                #   toplevel task of the fault response
                inherited_single_value_attribute :action

                def locate_on_missions
                    response_location :missions
                    self
                end

                def locate_on_actions
                    response_location :actions
                    self
                end

                def locate_on_origin
                    response_location :origin
                    self
                end

                def try_again
                    __try_again(true)
                end

                def find_response_locations(origin)
                    if response_location == :origin
                        return [origin].to_set
                    end

                    predicate =
                        if response_location == :missions
                            proc { |t| t.mission? && t.running? }
                        elsif response_location == :actions
                            proc { |t| t.running? && t.planning_task && t.planning_task.kind_of?(Roby::Actions::Task) }
                        end

                    result = Set.new
                    Roby::TaskStructure::Dependency.reverse.each_dfs(origin, BGL::Graph::TREE) do |_, to, _|
                        if predicate.call(to)
                            result << to
                            Roby::TaskStructure::Dependency.prune
                        end
                    end
                    result
                end

                def activate(origin, failure_event = nil, arguments = Hash.new)
                    locations = find_response_locations(origin)
                    if locations.empty?
                        Roby.warn "#{self} did match an exception, but the response location #{response_location} does not match anything"
                        return
                    end

                    plan = origin.plan

                    # Create the response task
                    plan.add(response_task = FaultHandlingTask.new)
                    response_task.fault_handler = self
                    new(action_interface, response_task, arguments)
                    response_task.start!
                    locations.each do |task|
                        # Mark :stop as handled by the response task and kill
                        # the task
                        #
                        # In addition, if origin == task, we need to handle the
                        # error events as well
                        task.stop_event.handle_with(response_task)
                        if task == origin && failure_event
                            # Add a error handling relation, explaining what the
                            # response task does
                            failure_event.generator.handle_with(response_task)
                            plan.add_repair(failure_event, response_task)
                        end
                        # In any case, we do declare the error handling relation
                        task.add_error_handler(response_task, Set.new)
                    end
                    locations.each do |task|
                        # This should not be needed. However, the current GC
                        # implementation in ExecutionEngine does not stop at
                        # finished tasks, and therefore would not GC the
                        # underlying tasks
                        task.remove_children(Roby::TaskStructure::Dependency)
                        task.stop! if task.running?
                    end
                end
            end
        end
    end
end

