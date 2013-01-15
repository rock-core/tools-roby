module Roby
    module Actions
        # A representation of an event on a state
        class StateEvent
            attr_reader :state
            attr_reader :symbol
            def initialize(state, symbol)
                @state, @symbol = state, symbol
            end
        end

        # A representation of an event on the toplevel state machine
        class StateMachineEvent
            # The state machine model this event is defined on
            # @return [Model<StateMachine>]
            attr_reader :state_machine
            # The event symbol
            # @return [Symbol]
            attr_reader :symbol
            def initialize(state_machine, symbol)
                @state_machine, @symbol = state_machine, symbol
            end
        end

        # A representation of a state as a binding of a selected action and
        # arguments
        class State
            attr_reader :action
            attr_reader :arguments
            attr_accessor :name

            def initialize(action, arguments)
                @action, @arguments = action, arguments
                @name = action.name
            end

            # Returns the state event for the given event on this state
            def find_event(name)
                if ev = action.returned_type.find_event(name.to_sym)
                    StateEvent.new(self, ev.symbol)
                end
            end

            # Generates a task for this state in the given plan and returns
            # it
            def instanciate(plan)
                action.instanciate(plan, arguments)
            end
            
            def method_missing(m, *args, &block)
                if m.to_s =~ /(\w+)_event$/
                    ev_name = $1
                    if !args.empty?
                        raise ArgumentError, "expected zero arguments, got #{args.size}"
                    end
                    ev = find_event(ev_name)
                    if !ev
                        raise NoMethodError, "#{ev_name} is not an event of #{action.returned_type}"
                    end
                    return ev
                else return super
                end
            end
        end

        # Definition of model-level functionality for StateMachine models
        module StateMachineModel
            # The action model for this state machine
            # @return [Model<Roby::Task>] a subclass of Roby::Task
            attr_accessor :task_model
            # The action interface model this state machine model is defined on
            # @return [InterfaceModel]
            attr_accessor :action_interface
            # The starting state
            # @return [State]
            attr_reader :starting_state

            # The set of defined states
            # @return [Array<State>]
            define_inherited_enumerable(:state, :states) { Array.new }
            # The set of defined transitions, as (State,EventName)=>State
            # @return [Array<(StateEvent,State)>]
            define_inherited_enumerable(:transition, :transitions) { Array.new }
            # The set of defined forwards, as (State,EventName)=>EventName
            # @return [Array<(StateEvent,TaskEvent)>]
            define_inherited_enumerable(:forward, :forwards) { Array.new }

            # Creates a new state machine model as a submodel of self
            #
            # @param [ActionInterfaceModel] action_interface the action
            #   interface model on which this state machine is defined
            # @param [Model<Roby::Task>] task_model the
            #   task model that is going to be used as a toplevel task for the
            #   state machine
            # @return [Model<StateMachine>] a subclass of StateMachine
            def new_submodel(action_interface, task_model = Roby::Task)
                submodel = Class.new(self)
                submodel.task_model = task_model
                submodel.action_interface = action_interface
                submodel
            end

            # Declares the starting state
            def start(state)
                @starting_state = state
            end

            # Declares a transition from a state to a new state, caused by an
            # event
            def transition(state_event, new_state)
                transitions << [state_event.state, state_event.symbol, new_state]
            end

            # Declares that the given event on the root task of the state should
            # be forwarded to an event on this task
            def forward(state_event, root_event)
                forwards << [state_event.state, state_event.symbol, root_event.symbol]
            end

            # Evaluates a state machine definition block
            def parse(&block)
                instance_eval(&block)
            end

            # Returns an object that can be used to refer to an event of the
            # toplevel task on which this state machine model applies
            def find_event(event_name)
                if event = task_model.find_event(event_name.to_sym)
                    StateMachineEvent.new(self, event.symbol)
                end
            end

            def method_missing(m, *args, &block)
                if action = action_interface.find_action_by_name(m.to_s)
                    if args.size > 1
                        raise ArgumentError, "expected zero or one argument to #{m}, got #{args.size}"
                    end
                    s = State.new(action, args.first || Hash.new)
                    states << s
                    s
                elsif m.to_s =~ /(.*)_event$/
                    find_event($1)
                else return super
                end
            end
        end

        module StateMachineInterface
            # Creates a state machine of actions
            def state_machine(name, &block)
                if !@current_description
                    raise ArgumentError, "you must describe the action with #describe before calling #state_machine"
                end

                root_m = @current_description.returned_type
                machine_model = StateMachine.new_submodel(self, root_m)
                machine_model.parse(&block)

                define_method(name) do
                    plan.add(root = root_m.new)
                    machine_model.new(root) 
                    root
                end
            end
        end
        Interface.extend StateMachineInterface

        # A state machine defined on action interfaces
        #
        # In such state machine, each state is represented by the task returned
        # by the corresponding action, and the transitions are events on these
        # tasks
        class StateMachine
            extend StateMachineModel

            # The task that represents this state machine. It must fullfill
            # {model}.task_model
            # @return [Roby::Task]
            attr_reader :root_task

            # The state machine model
            # @return [Model<StateMachine>] a subclass of StateMachine
            # @see StateMachineModel
            def model
                self.class
            end

            def initialize(root_task)
                @root_task = root_task
                root_task.execute do
                    instanciate_state(model.starting_state)
                end
            end

            def instanciate_state(state)
                known_transitions = Array.new
                model.transitions.each do |src_state, src_event, dst_state|
                    if state == src_state
                        known_transitions << src_event
                    end
                end

                root_task.depends_on(task = state.instanciate(root_task.plan), :role => state.name, :failure => :stop, :success => known_transitions)
                model.transitions.each do |src_state, src_event, dst_state|
                    if state == src_state
                        task.on(src_event) do |context|
                            instanciate_state_transition(task, dst_state)
                        end
                    end
                end
                model.forwards.each do |src_state, src_event, dst_event|
                    if state == src_state
                        task.event(src_event).forward_to root_task.event(dst_event)
                    end
                end
                task
            end

            def instanciate_state_transition(task, new_state)
                new_task = instanciate_state(new_state)
                new_task.should_start_after task.stop_event
                root_task.remove_dependency task
                new_task
            end
        end
    end
end

