module Roby
    module Coordination
        # A way to organize response to faults (a.k.a. Roby exceptions)
        #
        # Fault response tables are defined as subclasses of this class, e.g.
        #
        # @example
        #   class MyTable < FaultResponseTable
        #     on_fault with_origin(TaskModel.power_off_event) do
        #       # Fault response description
        #     end
        #   end
        #
        # Where the content of a fault handler is an {Coordination::ActionScript} with the
        # following additional statements:
        #  * locate_on_missions: the fault response will be assigned to the
        #    downmost missions which are affected by the fault.
        #  * locate_on_actions:  the fault response will be assigned to the
        #    downmost actions which are affected by the fault. This is the
        #    default.
        #  * locate_on_origins: the fault response will be assigned to the fault
        #    origin
        #  * restart: if specified, the action, mission or task that was
        #    assigned to the fault handler will be restarted once the fault
        #    handler script terminates. It can optionally be given a number of
        #    allowed restarts (to avoid infinite loops) as well as a timeout (to
        #    reset the counter if the fault did not occur for a certain length
        #    of time)
        #
        # And can then be attached to running plans through the action
        # interface:
        #  
        # @example enable a fault response table globally
        #   use_fault_response_table MyTable
        #
        # @example enable this fault response table whenever a task matching this matcher
        #   use_fault_response_table MyTable, when: MyTaskModel.mission
        # 
        # @example enable this fault response table when this action is running
        #   use_fault_response_table MyTable, when: an_action
        #
        # @example dynamically enable/disable tables programatically
        #   Roby.plan.use_fault_response_table MyTable
        #   Roby.plan.remove_fault_response_table MyTable
        #
        class FaultResponseTable < Roby::Actions::Interface
            extend Models::FaultResponseTable

            # @return [{Symbol=>Object}] assigned table arguments
            attr_reader :arguments

            def initialize(plan, arguments = Hash.new)
                # Argument massaging must be done before we call super(), as
                # super() will attach the table on the plan
                @arguments = model.validate_arguments(arguments)
                super(plan)
            end

            # Hook called when this table is attached to a given plan
            #
            # This is a hook, so one can inject code here by defining a
            # attach_to method on a module and including this module on the
            # FaultResponseTable class. Do not forget to add
            #
            #   super if defined? super
            #
            # in the hook method.
            #
            # @param [Plan] plan
            # @return [void]
            def attach_to(plan)
                super if defined? super
            end

            # Returns the handlers that are defined for a particular exception
            #
            # @param [ExecutionException] exception the exception that should be
            #   matched
            # @return [Array<Models::FaultHandler>]
            def find_all_matching_handlers(exception)
                model.find_all_matching_handlers(exception)
            end

            # Called when this table has been removed from the plan it was
            # attached to
            #
            # It cannot be reused afterwards
            #
            # It calls super if it is defined, so it is possible to use it as a
            # hook by defining a module that defines removed! and include it in
            # the FaultResponseTable class.
            #.
            # @return [void]
            def removed!
                super if defined? super
            end
        end
    end
end

