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

        # Placeholder, in the state machine definition, for variables. It is
        # used for instance to hold the arguments to the state machine during
        # modelling, replaced by their values during instanciation
        StateMachineVariable = Struct.new :name

        # Generic representation of a state in a StateMachine
        #
        # It requires to be given a task model, which is the model of the task
        # that is going to represent the state at runtime, and an
        # instanciation object. The latter is simply an object on which
        # #instanciate(plan) is going to be called when the state is entered and
        # should return the task that is executing the state
        #
        # In a given StateMachineModel, a state is represented by an unique
        # instance of State or of one of its subclasses
        class State
            attr_reader :task_model

            def initialize(task_model)
                @task_model = task_model
            end

            # Returns the state event for the given event on this state
            def find_event(name)
                if ev = task_model.find_event(name.to_sym)
                    StateEvent.new(self, ev.symbol)
                end
            end

            def method_missing(m, *args, &block)
                if m.to_s =~ /(\w+)_event$/
                    ev_name = $1
                    if !args.empty?
                        raise ArgumentError, "expected zero arguments, got #{args.size}"
                    end
                    ev = find_event(ev_name)
                    if !ev
                        raise NoMethodError, "#{ev_name} is not an event of #{self}"
                    end
                    return ev
                else return super
                end
            end
        end

        class StateFromInstanciationObject < State
            attr_reader :instanciation_object

            def initialize(instanciation_object, task_model)
                super(task_model)
                @instanciation_object = instanciation_object
            end

            def instanciate(plan, variables)
                instanciation_object.instanciate(plan)
            end
        end

        # A representation of a state based on an action
        class StateFromAction < State
            # The associated action
            # @return [Roby::Actions::Action]
            attr_reader :action

            def initialize(action)
                @action = action
                super(action.model.returned_type)
            end

            # Generates a task for this state in the given plan and returns
            # it
            def instanciate(plan, variables)
                arguments = action.arguments.map_value do |key, value|
                    if value.kind_of?(StateMachineVariable)
                        if variables.has_key?(value.name)
                            variables[value.name]
                        else
                            raise ArgumentError, "expected a value for #{arg}, got none"
                        end
                    else value
                    end
                end
                action.instanciate(plan, arguments)
            end
        end

        # State whose instanciation object is provided through a state machine
        # variable
        class StateFromVariable < State
            attr_reader :variable_name
            def initialize(variable_name, task_model)
                @variable_name = variable_name
                super(task_model)
            end

            def instanciate(plan, variables)
                obj = variables[variable_name]
                if !obj.respond_to?(:instanciate)
                    raise ArgumentError, "expected variable #{variable_name} to contain an object that can generate tasks, found #{obj}"
                end
                obj.instanciate(plan)
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
            # The set of arguments available on this state machine
            # @return [Array<Symbol>]
            define_inherited_enumerable(:argument, :arguments) { Array.new }

            # Creates a new state machine model as a submodel of self
            #
            # @param [ActionInterfaceModel] action_interface the action
            #   interface model on which this state machine is defined
            # @param [Model<Roby::Task>] task_model the
            #   task model that is going to be used as a toplevel task for the
            #   state machine
            # @return [Model<StateMachine>] a subclass of StateMachine
            def new_submodel(action_interface, task_model = Roby::Task, arguments = Array.new)
                submodel = Class.new(self)
                submodel.task_model = task_model
                submodel.arguments.concat(arguments.map(&:to_sym).to_a)
                submodel.action_interface = action_interface
                submodel
            end

            def make_state(object, task_model = Roby::Task)
                if object.kind_of?(State)
                    return object
                elsif object.respond_to?(:to_action_state)
                    state = object.to_action_state
                    states << state
                    state
                elsif object.respond_to?(:instanciate)
                    state = State.new(object, task_model)
                    states << state
                    state
                elsif object.kind_of?(StateMachineVariable)
                    state = StateFromVariable.new(object.name, task_model)
                    states << state
                    state
                else raise ArgumentError, "cannot create a state from #{object}"
                end
            end

            def validate_state(object)
                if !object.kind_of?(State)
                    raise ArgumentError, "expected a state object, got #{object}. Did you forget to define a state with #make_state first ?"
                end
                object
            end

            # Declares the starting state
            def start(state)
                @starting_state = validate_state(state)
            end

            # Declares a transition from a state to a new state, caused by an
            # event
            def transition(state_event, new_state)
                transitions << [state_event.state, state_event.symbol, validate_state(new_state)]
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

            # Returns true if this is the name of an argument for this state
            # machine model
            def has_argument?(name)
                each_argument.any? { |n| n == name }
            end

            def method_missing(m, *args, &block)
                if has_argument?(m)
                    if args.size != 0
                        raise ArgumentError, "expected zero arguments to #{m}, got #{args.size}"
                    end
                    StateMachineVariable.new(m)
                elsif action = action_interface.find_action_by_name(m.to_s)
                    s = StateFromAction.new(action_interface.send(m, *args, &block))
                    states << s
                    s
                elsif m.to_s =~ /(.*)_event$/
                    find_event($1)
                else return super
                end
            end
        end

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

            # The set of arguments given to this state machine model
            # @return [Hash]
            attr_reader :arguments

            # The state machine model
            # @return [Model<StateMachine>] a subclass of StateMachine
            # @see StateMachineModel
            def model
                self.class
            end

            def initialize(root_task, arguments = Hash.new)
                @root_task = root_task
                @arguments = Kernel.normalize_options arguments
                model.arguments.each do |key|
                    if !@arguments.has_key?(key)
                        raise ArgumentError, "expected an argument named #{key} but got none"
                    end
                end
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

                root_task.depends_on(task = state.instanciate(root_task.plan, arguments),
                            :role => 'current_state',
                            :failure => :stop,
                            :success => known_transitions,
                            :remove_when_done => false)
                model.transitions.each do |src_state, src_event, dst_state|
                    if state == src_state
                        task.on(src_event) do |event|
                            instanciate_state_transition(event.task, dst_state)
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

