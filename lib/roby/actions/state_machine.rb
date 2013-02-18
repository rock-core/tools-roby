require 'roby/actions/calculus'
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
        StateMachineVariable = Struct.new :name do
            include Tools::Calculus::Build
            def evaluate(variables)
                if variables.has_key?(name)
                    variables[name]
                else
                    raise ArgumentError, "expected a value for #{arg}, got none"
                end
            end
        end

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
            attr_reader :dependencies

            def initialize(task_model)
                @task_model = task_model
                @dependencies = Set.new
            end

            # Returns the state event for the given event on this state
            def find_event(name)
                if ev = task_model.find_event(name.to_sym)
                    StateEvent.new(self, ev.symbol)
                end
            end

            def depends_on(action, options = Hash.new)
                options = Kernel.validate_options options, :role
                StateMachineModel.validate_state(action)
                dependencies << [action, options[:role]]
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

            def instanciate(action_interface_model, plan, variables)
                instanciation_object.instanciate(plan)
            end

            def to_s; "#{instanciation_object}[#{task_model}]" end
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
            def instanciate(action_interface_model, plan, variables)
                arguments = action.arguments.map_value do |key, value|
                    if value.respond_to?(:evaluate)
                        value.evaluate(variables)
                    else value
                    end
                end
                action.rebind(action_interface_model).instanciate(plan, arguments)
            end

            def to_s; "action(#{action})[#{task_model}]" end
        end

        # State whose instanciation object is provided through a state machine
        # variable
        class StateFromVariable < State
            attr_reader :variable_name
            def initialize(variable_name, task_model)
                @variable_name = variable_name
                super(task_model)
            end

            def instanciate(action_interface_model, plan, variables)
                obj = variables[variable_name]
                if !obj.respond_to?(:instanciate)
                    raise ArgumentError, "expected variable #{variable_name} to contain an object that can generate tasks, found #{obj}"
                end
                obj.instanciate(plan)
            end

            def to_s; "var(#{variable_name})[#{task_model}]" end
        end

        # Definition of model-level functionality for StateMachine models
        module StateMachineModel
            include MetaRuby::ModelAsClass

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
            inherited_attribute(:state, :states) { Array.new }
            # The set of defined transitions, as (State,EventName)=>State
            # @return [Array<(StateEvent,State)>]
            inherited_attribute(:transition, :transitions) { Array.new }
            # The set of defined forwards, as (State,EventName)=>EventName
            # @return [Array<(StateEvent,TaskEvent)>]
            inherited_attribute(:forward, :forwards) { Array.new }
            # The set of arguments available on this state machine
            # @return [Array<Symbol>]
            inherited_attribute(:argument, :arguments) { Array.new }
            # A set of actions that should always be active when this state
            # machine is running
            # @return [Set<State>]
            inherited_attribute(:dependency, :dependencies) { Set.new }

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

            # Creates a state from an object
            def state(object, task_model = Roby::Task)
                if object.kind_of?(Action)
                    state = StateFromAction.new(object)
                    states << state
                    state
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

            def self.validate_state(object)
                if !object.kind_of?(State)
                    raise ArgumentError, "expected a state object, got #{object}. Did you forget to define it by calling #state first ?"
                end
                object
            end

            # Declares the starting state
            def start(state)
                @starting_state = StateMachineModel.validate_state(state)
            end

            # Declares a transition from a state to a new state, caused by an
            # event
            #
            # @overload transition(state.my_event, new_state)
            #   declares that once the 'my' event on the given state is emitted,
            #   we should transition to new_state
            # @overload transition(state, event, new_state)
            #   declares that, while in state 'state', transition to 'new_state'
            #   if the given event is emitted
            #
            def transition(*spec)
                if spec.size == 2
                    state_event, new_state = *spec
                    transition(state_event.state, state_event, StateMachineModel.validate_state(new_state))
                elsif spec.size != 3
                    raise ArgumentError, "expected 2 or 3 arguments, got #{spec.size}"
                else
                    state, state_event, new_state = *spec
                    transitions << [state, state_event, StateMachineModel.validate_state(new_state)]
                end
            end

            # Declares that the given event on the root task of the state should
            # be forwarded to an event on this task
            #
            # @overload forward(state.my_event, target_event)
            #   declares that, while in state 'state', forward 'my_event' to the
            #   given event name on the state machine task
            # @overload forward(state, event, target_event)
            #   declares that, while in state 'state', forward 'event' to the
            #   given event name on the state machine task
            #
            def forward(*spec)
                if spec.size == 2
                    state_event, target_event = *spec
                    forward(state_event.state, state_event, target_event)
                elsif spec.size != 3
                    raise ArgumentError, "expected 2 or 3 arguments, got #{spec.size}"
                else
                    state, event, target_event = *spec
                    forwards << [state, event, target_event.symbol]
                end
            end

            def depends_on(task, options = Hash.new)
                options = Kernel.validate_options options, :role
                task = StateMachineModel.validate_state(task)
                dependencies << [task, options[:role]]
                task
            end

            # Returns the set of actions that should be active when in state
            # +state+.
            #
            # It includes state itself, as state should run when it is active
            # @return [Set<State>]
            def required_actions_in_state(state)
                result = Hash.new
                state.dependencies.each do |action, role|
                    result[action] ||= Set.new
                    result[action] << role if role
                end
                each_dependency do |action, role|
                    result[action] ||= Set.new
                    result[action] << role if role
                end
                result[state] ||= Set.new
                result[state] << 'current_state'
                result
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
                    action_interface.send(m, *args, &block)
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
            # model.task_model
            # @return [Roby::Task]
            attr_reader :root_task

            # The set of arguments given to this state machine model
            # @return [Hash]
            attr_reader :arguments

            # The action interface model that is supporting this state machine
            attr_reader :action_interface_model

            # The state machine model
            # @return [Model<StateMachine>] a subclass of StateMachine
            # @see StateMachineModel
            def model
                self.class
            end

            # The current state
            attr_reader :current_state

            # Resolved form of the state machine model
            #
            # It is a mapping from a state to the information required to
            # instanciate this state
            attr_reader :state_info

            def initialize(action_interface_model, root_task, arguments = Hash.new)
                @action_interface_model = action_interface_model
                @root_task = root_task
                @arguments = Kernel.normalize_options arguments
                model.arguments.each do |key|
                    if !@arguments.has_key?(key)
                        raise ArgumentError, "expected an argument named #{key} but got none"
                    end
                end
                root_task.execute do
                    if model.starting_state
                        instanciate_state(model.starting_state)
                    end
                end

                @state_info = generate_state_info
            end

            def generate_state_info
                result = Hash.new
                model.each_state do |state|
                    actions = model.required_actions_in_state(state)
                    transitions = Hash.new
                    forwards = Hash.new
                    model.each_transition do |in_state, event, new_state|
                        if in_state == state
                            actions[event.state] ||= Set.new
                            transitions[event.state] ||= Set.new
                            transitions[event.state] << [event.symbol, new_state]
                        end
                    end
                    model.each_forward do |in_state, event, target_symbol|
                        if in_state == state
                            actions[event.state] ||= Set.new
                            forwards[event.state] ||= Set.new
                            forwards[event.state] << [event.symbol, target_symbol]
                        end
                    end
                    actions.each_key do |a|
                        forwards[a] ||= Array.new
                        transitions[a] ||= Array.new
                    end
                    result[state] = [actions, transitions, forwards]
                end
                result
            end

            def instanciate_state(state)
                actions, known_transitions, forwards = state_info[state]
                actions.each do |action, roles|
                    root_task.depends_on(task = action.instanciate(action_interface_model, root_task.plan, arguments),
                                :roles => roles,
                                :failure => :stop,
                                :success => known_transitions[action].map(&:first),
                                :remove_when_done => true)

                    known_transitions[action].each do |src_symbol, dst_state|
                        task.on(src_symbol) do |event|
                            instanciate_state_transition(event.task, dst_state)
                        end
                    end
                    forwards[action].each do |src_event, dst_event|
                        task.event(src_event).forward_to root_task.event(dst_event)
                    end
                end
                @current_state = state
                root_task.current_state_child
            end

            def instanciate_state_transition(task, new_state)
                current_state_child = root_task.find_child_from_role('current_state')
                state_info[current_state].first.each do |_, roles|
                    if child_task = root_task.find_child_from_role(roles.first)
                        root_task.remove_dependency(child_task)
                    end
                end
                new_task = instanciate_state(new_state)
                new_task
            end
        end
    end
end

