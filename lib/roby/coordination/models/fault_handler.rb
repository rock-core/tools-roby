# frozen_string_literal: true

module Roby
    module Coordination
        module Models
            # Definition of a single fault handler in a FaultResponseTable
            module FaultHandler
                include Actions
                include Script

                # @return [FaultResponseTable] the table this handler is part of
                def fault_response_table
                    action_interface
                end
                # @return [Queries::ExecutionExceptionMatcher] the object
                #   defining for which faults this handler should be activated
                inherited_single_value_attribute(:execution_exception_matcher) { Queries.none }
                # @return [Integer] this handler's priority
                inherited_single_value_attribute(:priority) { 0 }
                # @return [:missions,:actions,:origin] the fault response
                #   location
                inherited_single_value_attribute(:response_location) { :actions }
                # @return [Boolean] if true, the action location will be retried
                #   after the fault response table, otherwise whatever should
                #   happen will happen (other error handling, ...)
                inherited_single_value_attribute(:__carry_on) { false }
                # @return [Boolean] if true, the last action of the response
                #   will be to retry whichever action/missions/tasks have been
                #   interrupted by the fault
                def carry_on?
                    !!__carry_on
                end

                # @deprecated use {#carry_on?}
                def try_again?
                    carry_on?
                end
                # @return [#instanciate] an object that allows to create the
                #   toplevel task of the fault response
                inherited_single_value_attribute :action

                def to_s
                    "#{fault_response_table}.on_fault(#{execution_exception_matcher})"
                end

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

                # Try the repaired action again when the fault handler
                # successfully finishes
                #
                # It can be called anytime in the script, but will have an
                # effect only at the end of the fault handler
                def carry_on
                    __carry_on(true)
                    terminal
                end

                # @deprecated use {#carry_on}
                def try_again
                    carry_on
                end

                # Script element that implements the replacement part of
                # {#replace_by}
                class ReplaceBy < Coordination::ScriptInstruction
                    attr_reader :replacement_task

                    def initialize(replacement_task)
                        super()

                        @replacement_task = replacement_task
                    end

                    def new(fault_handler)
                        ReplaceBy.new(fault_handler.instance_for(replacement_task))
                    end

                    def execute(fault_handler)
                        response_task = fault_handler.root_task
                        plan = response_task.plan
                        replacement_task = self.replacement_task.resolve

                        response_task.each_parent_object(Roby::TaskStructure::ErrorHandling) do |repaired_task|
                            repaired_task_parents = repaired_task.each_parent_task.map do |parent_task|
                                [parent_task, parent_task[repaired_task, Roby::TaskStructure::Dependency]]
                            end
                            plan.replace(repaired_task, replacement_task)
                            repaired_task_parents.each do |parent_t, dependency_options|
                                parent_t.add_child repaired_task, dependency_options
                            end
                        end
                        true
                    end

                    def to_s
                        "start(#{task}, #{dependency_options})"
                    end
                end

                class FinalizeReplacement < Coordination::ScriptInstruction
                    def new(fault_handler)
                        self
                    end

                    def execute(fault_handler)
                        response_task = fault_handler.root_task
                        response_task.each_parent_object(Roby::TaskStructure::ErrorHandling) do |repaired_task|
                            repaired_task_parents = repaired_task.each_parent_task.to_a
                            repaired_task_parents.each do |parent|
                                parent.remove_child repaired_task
                            end
                        end
                    end
                end

                # Replace the response's location by this task when the fault
                # handler script is finished
                #
                # It terminates the script, i.e. no instructions can be added
                # after it is called
                #
                # @raise ArgumentError if there is already a replacement task
                def replace_by(task, until_event = nil)
                    __carry_on(false)
                    replacement_task = validate_or_create_task(task)
                    start replacement_task
                    instructions << ReplaceBy.new(replacement_task)
                    wait(until_event || replacement_task.success_event)
                    instructions << FinalizeReplacement.new
                    emit success_event
                    terminal
                end

                class ResponseLocationVisitor < RGL::DFSVisitor
                    attr_reader :predicate, :selected

                    def initialize(graph, predicate)
                        super(graph)
                        @predicate = predicate
                        @selected = Set.new
                    end

                    def handle_examine_vertex(u)
                        if predicate.call(u)
                            selected << u
                        end
                    end

                    def follow_edge?(u, v)
                        if selected.include?(u)
                            false
                        else super
                        end
                    end
                end

                def find_response_locations(origin)
                    return [origin].to_set if response_location == :origin

                    predicate =
                        case response_location
                        when :missions
                            proc { |t| t.mission? && t.running? }
                        when :actions
                            proc { |t| t.running? && t.planning_task && t.planning_task.kind_of?(Roby::Actions::Task) }
                        end

                    search_graph = origin.plan
                        .task_relation_graph_for(TaskStructure::Dependency)
                        .reverse
                    visitor = ResponseLocationVisitor.new(search_graph, predicate)
                    search_graph.depth_first_visit(origin, visitor) {}
                    visitor.selected
                end

                # @api private
                #
                # Activate this fault handler for the given exception and
                # arguments. It creates the {FaultHandlingTask} and attaches the
                # handler on it as an action script.
                #
                # @param [ExecutionException] exception
                # @param [Hash] arguments
                def activate(exception, arguments = {})
                    locations = find_response_locations(exception.origin)
                    if locations.empty?
                        Roby.warn "#{self} did match an exception, but the response location #{response_location} does not match anything"
                        return
                    end

                    plan = exception.origin.plan

                    # Create the response task
                    plan.add(response_task = FaultHandlingTask.new)
                    response_task.fault_handler = self
                    new(response_task, arguments)
                    response_task.start!
                    locations.each do |task|
                        # Mark :stop as handled by the response task and kill
                        # the task
                        #
                        # In addition, if origin == task, we need to handle the
                        # error events as well
                        task.add_error_handler(
                            response_task,
                            [task.stop_event.to_execution_exception_matcher,
                             execution_exception_matcher].to_set
                        )
                    end

                    locations.each do |task| # rubocop:disable Style/CombinableLoops
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
