module Roby
    module Actions
        # Model part of ExecutionContext
        module ExecutionContextModel
            include MetaRuby::ModelAsClass

            # A representation of an event on the execution context's task
            class Event
                # @return [ExecutionContext,Task] The task this event is defined on
                attr_reader :task_model
                # @return [Symbol] the event's symbol
                attr_reader :symbol

                def initialize(task_model, symbol)
                    @task_model, @symbol = task_model, symbol.to_sym
                end

                def bind(task)
                    @task = task
                    task_model.bind(task)
                end

                def resolve
                    task_model.resolve.event(symbol)
                end

                def method_missing(m, *args, &block)
                    if @task # we are bound to something
                        resolve.send(m, *args, &block)
                    elsif task_model.respond_to?(:method_defined?) && task_model.method_defined?(m)
                        raise NoMethodError, "#{self} is not yet bound to any actual task. You will be able to call ##{m} only when the underlying task is started"
                    else super
                    end
                end
            end

            # A task within an execution context
            class Task
                # The task model
                attr_reader :model

                def initialize(model)
                    @model = model
                end

                def bind(task)
                    @task = task
                end

                def find_event(event_name)
                    if model && model.respond_to?(:find_event)
                        if event_model = model.find_event(event_name.to_sym)
                            return Event.new(self, event_name)
                        else
                        end
                    else return Event.new(self, event_name)
                    end
                end

                def find_child(role)
                    if model && model.respond_to?(:find_child)
                        if child_model = model.find_child(role)
                            return Child.new(self, role, child_model)
                        else
                            raise ArgumentError, "#{model.name} has no child called #{role}"
                        end
                    else return Child.new(self, role, child_model)
                    end
                end

                def method_missing(m, *args, &block)
                    case m.to_s
                    when /^(.*)_event$/
                        event_name = $1
                        if event = find_event(event_name)
                            event.bind(@task) if @task
                            return event
                        else
                            raise ArgumentError, "#{model.name} has no event called #{event_name}"
                        end
                    when /^(.*)_child$/
                        role = $1
                        if child = find_child(role)
                            child.bind(@task) if @task
                            return child
                        else
                            raise ArgumentError, "#{model.name} has no child with the role #{role}"
                        end
                    else
                        if @task # we are bound to something
                            resolve.send(m, *args, &block)
                        elsif task_model.respond_to?(:method_defined?) && task_model.method_defined?(m)
                            raise NoMethodError, "#{self} is not yet bound to any actual task. You will be able to call ##{m} only when the underlying task is started"
                        else super
                        end
                    end
                end
            end

            # The root task in the execution context
            class Root < Task
                def bind(task)
                    if !task.kind_of?(model)
                        raise ArgumentError, "cannot bind #{self} to #{task}: was expecting an object of type #{model}"
                    end
                    super
                end

                def resolve
                    @task
                end
            end

            # A representation of a task of the execution context's task
            class Child < Task
                # @return [ExecutionContext,Child] the child's parent
                attr_reader :parent
                # @return [String] the child's role, relative to its parent
                attr_reader :role
                # The child's model
                attr_reader :model

                def initialize(parent, role, model)
                    @parent, @role, @model = parent, role, model
                end

                def bind(task)
                    parent.bind(task)
                    super
                end
                
                def resolve
                    parent.resolve.child_from_role(role)
                end
            end

            # Placeholder, in the execution contexts, for variables. It is
            # used for instance to hold the arguments to the state machine during
            # modelling, replaced by their values during instanciation
            Variable = Struct.new :name do
                include Tools::Calculus::Build
                def evaluate(variables)
                    if variables.has_key?(name)
                        variables[name]
                    else
                        raise ArgumentError, "expected a value for #{arg}, got none"
                    end
                end

                def to_s
                    "var:#{name}"
                end
            end

            # @return [Root] the root task model, i.e. a representation of the
            #   task this execution context is going to be run on
            def root
                if @root then @root
                elsif superclass.respond_to?(:root)
                    superclass.root
                end
            end

            attr_writer :root

            # @return [Model<Roby::Task>] the task model this execution context
            #   is attached to
            def task_model; root.model end

            # The set of arguments available to this execution context
            # @return [Array<Symbol>]
            inherited_attribute(:argument, :arguments) { Array.new }

            # Creates a new execution context model as a submodel of self
            #
            # @param [Model<Roby::Task>] task_model the
            #   task model that is going to be used as a toplevel task for the
            #   state machine
            # @return [Model<StateMachine>] a subclass of StateMachine
            def new_submodel(task_model = Roby::Task, arguments = Array.new)
                submodel = super()
                submodel.root = Root.new(task_model)
                submodel.arguments.concat(arguments.map(&:to_sym).to_a)
                submodel
            end

            # Returns an object that can be used to refer to an event of the
            # toplevel task on which this state machine model applies
            def find_event(event_name)
                root.find_event(event_name)
            end

            # Returns an object that can be used to refer to the children of
            # this task from within the execution context
            def find_child(child_name)
                root.find_child(child_name)
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
                    Variable.new(m)
                elsif m.to_s =~ /(.*)_event$/
                    find_event($1)
                elsif m.to_s =~ /(.*)_child$/
                    find_child($1)
                else return super
                end
            end
        end
    end
end

