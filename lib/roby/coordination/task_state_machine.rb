require 'state_machine/machine'

module Roby
    # Helper to get a more roby-like feeling to the state machine definitions
    class StateMachineDefinitionContext
        attr_reader :task_model
        attr_reader :state_machine

        def initialize(task_model, state_machine)
            @task_model = task_model
            @state_machine = state_machine
        end

        def script_in_state(state, &block)
            script_engine = task_model.create_script(&block)

            state_machine.before_transition state_machine.any => state, do: lambda { |proxy|
                proxy.instance_variable_set :@script_engine, nil
            }
            state_machine.state(state) do
                define_method(:poll) do |task|
                    if !@script_engine
                        @script_engine = script_engine.bind(task)
                        @script_engine.prepare
                        @script_engine.step
                    end
                end
            end
        end

        def poll_in_state(state, &block)
            state_machine.state(state) do
                define_method(:poll, &block)
            end
        end

        def on(event, &block)
            state_machine.event(event, &block)
        end

        def method_missing(*args, &block)
            state_machine.send(*args, &block)
        end
    end

    # The state machine that can be associate with a task
    # 
    class TaskStateMachine
        # The proxy object class the state machine is working on
        attr_accessor :proxy

        # Underlying state machine
        attr_accessor :machine

        # Existing transitions
        # Transition comes with methods: event, from_name, to_name
        attr_reader :transitions

        # All state of the state machine
        attr_reader :states

        def initialize(machine)
            # Required to initialize underlying state_machine
            super()

            @proxy       = machine.owner_class.new
            @machine     = machine

            update
        end

        def update
            @states = []

            # introspect to retrieve all transactions of the statemachine
            @transitions = []
            collection = @machine.states
            collection.each do |s_o|
                collection.each do |s_i|
                    # status_transitions is added to TaskStateMachine using meta programming
                    transitions = proxy.status_transitions(from: s_o.name.to_sym, to: s_i.name.to_sym)
                    @transitions << transitions
                end
                @transitions.flatten!
            end

            # Infer all available states from existing transitions
            @transitions.each do |t|
                @states << t.from_name unless @states.index(t.from_name)
                @states << t.to_name unless @states.index(t.to_name)
            end
        end

        def initialize_copy(other)
            other.name = name 
            other.proxy = name.new
            other.machine = machine.dup
            other.update
        end

        def method_missing(method_name, *args, &block)
            # If proxy provides missing method, then use the proxy
            if proxy.respond_to?("#{method_name}")
                proxy.send(method_name, *args, &block)
            else
                # otherwise pass it on
                super
            end
        end

        # Define general poll handler
        def do_poll(task)
            begin 
                proxy.poll(task)
            rescue NoMethodError => e
                # poll only if the state has a poll handler defined
            end
        end

        # Identifies the current state given a list of subsequent events
        # Provides a list with the most recent event being last in the list
        # 
        def identify_state(event_list)
            # initalize with all transitions possible
            paths = {}
            @transitions.each do |transition|
                paths[transition] = []
            end

            paths = []
            new_paths = []
            initialized = false

            while event_list.size > 0 
                current_event = event_list.first
                # expand path
                @transitions.each do |transition|
                    # Get transitions that match event
                    if current_event == transition.event()
                        # expand first set of transactions
                        if not initialized
                            new_paths << [ transition ]
                        else
                            # find transitions that lead to the last transition
                            paths.each do |path|
                                if path.last.from_name == transition.to_name
                                    path << transition
                                    new_paths << path 
                                end
                            end
                        end
                    end
                end
                paths = new_paths
                new_paths = []
                initialized = true
                event_list.delete_at(0)
            end

            if paths.size == 1
                # Retrieve last (by time) transitions target state
                return paths[0].last.to_name
            elsif paths.size > 0
                throw "Event list is ambigious, requiring more events"
            end

            throw "Event list is invalid"
        end
    end # module TaskStateHelper

    # The TaskStateHelper allows to add a statemachine to 
    # a Roby::Task and allows the tracking of events within
    # the 'running' state
    module TaskStateHelper
        # The default namespace that is added to statemachine methods, e.g. 
        # when action for transitions are defined
        def namespace
            @namespace ||= nil 
        end

        def namespace=(name)
            @namespace=name
        end

        # Proxy object used in the definition of state machines on Roby::Task
        class Proxy
            def self.state_machine(*args, &block)
                StateMachine::Machine.find_or_create(self, *args, &block)
            end
        end

        # The state machine model that is running on all tasks of this task
        # model
        def state_machine
            if @state_machine then @state_machine
            elsif superclass.respond_to?(:state_machine)
                superclass.state_machine
            end
        end

        # Refine the running state of the Roby::Task
        # using a state machine description. The initial
        # state of the machine is set to 'running' by default.
        #
        # Example: 
        #     refine_running_state do
        #         on :pause do
        #             transition [:running] => paused
        #         end
        #         
        #         on :resume do
        #             transition [:paused] => :running
        #         end
        #         
        #         state :paused do
        #             def poll(task)
        #                 sleep 4
        #                 task.emit :resume
        #             end
        #         end
        #     end
        #
        # Events are translated into roby events 
        # and the statemachine in hooked into the
        # on(:yourevent) {|context| ... }
        # You can add additional event handlers as ususal
        # using on(:yourevent) .. syntax
        # 
        # The current status (substate of the running state)
        # can be retrieved via 
        #     yourtask.state_machine.status 
        # 
        def refine_running_state (*args, &block)
            if args.last.kind_of?(Hash) 
                options = args.pop
            end
            options = Kernel.validate_options(options || Hash.new, namespace: nil)

            if options.has_key?(:namespace)
                self.namespace=options[:namespace]
            end

            # Check if a model of a class ancestor already exists
            # If a parent_model exists, prepare the proxy class accordingly
            # The proxy allows us to use the state_machine library even
            # with instances 
            if parent_model = self.superclass.state_machine
                proxy_model = Class.new(parent_model.owner_class)
            else
                proxy_model = Class.new(Proxy)
            end

            # Create the state machine instance that will serve as base model
            # for instances of the Roby::Task (or its subclasses) this machine
            # is associated with The namespace allows to pre/postfix
            # automatically generated functions, such as for sending events:
            # <task>.state_machine.pause_<namespace>! or querying the status
            # <task>.state_machine.<namespace>_paused?  Note cannot use :state
            # instead of :status here for yet unknown reason Changing the
            # attribute :status also changes other method definitions, due to
            # meta programming approach of the underlying library, e.g.
            # status_transitions(from: ..., to: ...)

            if self.namespace 
                machine = StateMachine::Machine.find_or_create(proxy_model, :status, initial: :running, namespace: self.namespace)
            else
                machine = StateMachine::Machine.find_or_create(proxy_model, :status, initial: :running)
            end

            machine_loader = StateMachineDefinitionContext.new(self, machine)
            machine_loader.instance_eval(&block)
            @state_machine = machine

            import_events_to_roby(machine)
        end

        def import_events_to_roby(machine)
            # Roby requires the self to be the subclassed Roby::Task
            # Thus embed import into refine_running_state and using eval here
            machine.events.each do |e|
                if !has_event?(e.name)
                    event e.name, controlable: true
                end
                # when event is called transition the state_machine
                on(e.name) do |event|
                    state_machine.send("#{e.name.to_sym}!")
                end
            end
        end
    end

    class Task
        extend TaskStateHelper
        attr_reader :state_machine

        # Setup is done in #initialize
        # Polling is done in Task.do_poll
    end
end # module Roby

