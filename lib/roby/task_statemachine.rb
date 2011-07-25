require 'state_machine'

module Roby
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
    
    # Add functionality to StateMachine
    # Allows us to wrap existing methods in StateMachine
    StateMachine::Machine.class_eval do
        # Redefine the event signature to 
        # match Roby semantics
        def on(event, &block)
	    event(event, &block)
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
        options = Kernel.validate_options(options || Hash.new, :namespace => nil)

        if options.has_key?(:namespace)
            self.namespace=options[:namespace]
        end

        TaskStateMachine.models ||= Hash.new

        name = self
        # Making sure we load each machine definition only once per class 
        if TaskStateMachine.models.has_key?(name)
            return
        end

        # Check if a model of a class ancestor already exists
        # If a parent_model exists, prepare the proxy class accordingly
        # The proxy allows us to use the state_machine library even
        # with instances 
        if parent_model = TaskStateMachine.parent_model(name)
            proxy_klass = Class.new(parent_model.name)
        else
            proxy_klass = Class.new
        end
        
        # Create the state machine instance that will serve as base model for instances of the Roby::Task (or its subclasses) this
        # machine is associated with
        # The namespace allows to pre/postfix automatically generated functions, such as for sending events: <task>.state_machine.pause_<namespace>! or querying the status <task>.state_machine.<namespace>_paused?
        # Note cannot use :state instead of :status here for yet unknown reason
        # Changing the attribute :status also changes other method definitions, due to meta programming approach 
        # of the underlying library, e.g. status_transitions(:from => ..., :to => ...)

        if self.namespace 
            machine = StateMachine::Machine.find_or_create(proxy_klass, :status, :initial => :running, :namespace => self.namespace , &block)
        else
            machine = StateMachine::Machine.find_or_create(proxy_klass, :status, :initial => :running, &block)
        end

        import_events_to_roby(machine)
        task_state_machine = TaskStateMachine.new(proxy_klass, machine)
        
        # Add new state machine template
        TaskStateMachine.models[name] = task_state_machine

        # Hook the state_machine function into the callee
        #self.send(:instance_variable_set, :@state_machine, nil)
        self.send(:define_method, :state_machine) do
            @state_machine
        end
    end

    def import_events_to_roby(machine)

        # Roby requires the self to be the subclassed Roby::Task
        # Thus embed import into refine_running_state and using eval here
        machine.events.each do |e|
	    # When event is called emit event
	    self.send(:event, e.name.to_sym) do 
		send(:emit, e.name.to_sym)
	    end
            
	    # when event is called transition the state_machine
	    self.send(:on , e.name.to_sym) do |event|
		statemachine = send(:state_machine)
		begin
		    statemachine.send("#{e.name.to_sym}!".to_sym)
		rescue StateMachine::InvalidTransition => detail
		    puts "WARNING: invalid transition to #{e.name}"
		    puts "#{detail.backtrace}"
		end
	    end
        end
    end
end

# The state machine that can be associate with a task
# 
class TaskStateMachine
    
    # Underlying state machine library 
    attr_accessor :machine

    # Existing transitions
    # Transition comes with methods: event, from_name, to_name
    attr_reader :transitions

    # Name of the state machine i.e. Roby::Task name it is associated with
    attr_accessor :name

    attr_accessor :proxy
    
    # All state of the state machine
    attr_reader :all_states

    # Use singleton method to store already created statemachines
    # for loading the statemachine only once per task type
    class << self
        attr_accessor :models
        
        # Making sure we can deal with inheritance
        def from_model(model_klass)
            TaskStateMachine.models ||= Hash.new

            TaskStateMachine.models.each do |key_model, statemachine_model|
                if model_klass.class == key_model
                    return statemachine_model.dup
                end
            end
            
	    # If the is no model returning nil 
	    # "#{model_klass} is not a known TaskStateMachine model"
	    nil
        end

        def parent_model(model_klass)
            TaskStateMachine.models.each do |key_model, statemachine_model|
	        # Check if model_klass inherits from key_model
                if model_klass < key_model
                    return statemachine_model.dup
                end
            end
            
	    # If the is no model returning nil 
	    # "#{model_klass} is not a known TaskStateMachine model"
	    nil
	end

    end

    def initialize(name, machine)
        # Required to initialize underlying state_machine
        super()

        TaskStateMachine.models ||= Hash.new
        @name = name
        @proxy = name.new
        @machine = machine.dup

        update
    end

    def update
        @all_states = []

        # introspect to retrieve all transactions of the statemachine
        @transitions = []
        collection = @machine.states
        collection_outer = @machine.states
        collection_outer.each do |s_o|
            collection.each do |s_i|
                # status_transitions is added to TaskStateMachine using meta programming
                transitions = proxy.status_transitions(:from => s_o.name.to_sym, :to => s_i.name.to_sym)
                @transitions << transitions
            end
            @transitions.flatten!
        end

        # Infer all available states from existing transitions
        @transitions.each do |t|
            @all_states << t.from_name unless @all_states.index(t.from_name)
            @all_states << t.to_name unless @all_states.index(t.to_name)
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

end # module Roby

Class.class_eval do
    include Roby::TaskStateHelper
end
