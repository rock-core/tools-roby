# frozen_string_literal: true

module Roby
    module Coordination
        module Models
            # Model part of Base
            module Base
                include MetaRuby::ModelAsClass
                include Arguments

                # Name of this coordination object
                #
                # For debugging purposes. It is usually set by the enclosing context
                #
                # @return [String,nil]
                attr_accessor :name

                # Gets or sets the root task model
                #
                # @return [Root] the root task model, i.e. a representation of the
                #   task this execution context is going to be run on
                def root(*new_root)
                    if !new_root.empty?
                        @root = Root.new(new_root.first, self)
                    elsif @root then @root
                    elsif superclass.respond_to?(:root)
                        @root = superclass.root.rebind(self)
                    end
                end

                # @deprecated use {#root} instead, as it is a more DSL-like API
                attr_writer :root

                # @return [Model<Roby::Task>] the task model this execution context
                #   is attached to
                def task_model
                    root.model
                end

                # Gives direct access to the root's events
                #
                # This is needed to be able to use a coordination model as model for
                # a coordination task, which in turn gives access to e.g. states in
                # an action state machine
                def find_event(name)
                    root.find_event(name)
                end

                # Returns the task for the given name, if found, nil otherwise
                #
                # @return Roby::Coordination::Models::TaskFromAction
                def find_task_by_name(name)
                    tasks.find do |m|
                        m.name == name.to_s
                    end
                end

                # The set of defined tasks
                # @return [Array<Task>]
                inherited_attribute(:task, :tasks) { [] }

                # The set of fault response tables that should be active when this
                # coordination model is
                # @return [Array<(FaultResponseTable,Hash)>]
                inherited_attribute(:used_fault_response_table, :used_fault_response_tables) { [] }

                # Creates a new execution context model as a submodel of self
                #
                # @param [Model<Roby::Task>] subclass the
                #   task model that is going to be used as a toplevel task for the
                #   state machine
                # @return [Model<StateMachine>] a subclass of StateMachine
                def setup_submodel(subclass, root: Roby::Task, **options)
                    subclass.root(root)
                    super
                end

                # Creates a state from an object
                def task(object, task_model = Roby::Task)
                    if object.respond_to?(:to_coordination_task)
                        task = object.to_coordination_task(task_model)
                        tasks << task
                        task
                    elsif object.respond_to?(:as_plan)
                        task = TaskFromAsPlan.new(object, task_model)
                        tasks << task
                        task
                    else
                        raise ArgumentError, "cannot create a task from #{object}"
                    end
                end

                # @api private
                #
                # Transform the model by exchanging tasks
                #
                # @param [#[]] mapping a mapping that replaces an existing task by a
                #   new one. All tasks must be mapped
                def map_tasks(mapping)
                    @root  = mapping.fetch(root)
                    @tasks = tasks.map do |t|
                        new_task = mapping.fetch(t)
                        new_task.map_tasks(mapping)
                        new_task
                    end
                end

                # Assigns names to tasks based on the name of the local variables
                # they are assigned to
                #
                # This must be called by methods that are themselves called during
                # parsing
                #
                # @param [Array<String>] suffixes that should be added to all the names
                def parse_names(suffixes)
                    definition_context = binding.callers.find { |b| b.frame_type == :block }
                    return unless definition_context

                    # Assign names to tasks using the local variables
                    definition_context.local_variables.each do |var|
                        object = definition_context.local_variable_get(var)
                        suffixes.each do |klass, suffix|
                            if object.kind_of?(klass)
                                object.name = "#{var}#{suffix}"
                            end
                        end
                    end
                end

                def respond_to_missing?(m, include_private)
                    has_argument?(m) ||
                        (m =~ /_event$|_child$/ && root.respond_to?(m)) ||
                        super
                end

                def method_missing(m, *args, **kw, &block)
                    if has_argument?(m)
                        unless args.empty? && kw.empty?
                            raise ArgumentError,
                                  "expected zero arguments to #{m}, "\
                                  "got #{args.size} positional arguments (#{args}) and "\
                                  "#{kw.size} keyword arguments (#{kw})"
                        end

                        Variable.new(m)
                    elsif m =~ /(.*)(?:_event$|_child$)/
                        root.send(m, *args, &block)
                    else
                        super
                    end
                end

                def validate_task(object)
                    unless object.kind_of?(Coordination::Models::Task)
                        raise ArgumentError,
                              "expected a state object, got #{object}. States "\
                              "need to be created from e.g. actions by calling "\
                              "#state before they can be used in the state machine"
                    end

                    object
                end

                def validate_or_create_task(task)
                    if !task.kind_of?(Coordination::Models::Task)
                        task(task)
                    else
                        task
                    end
                end

                def validate_event(object)
                    unless object.kind_of?(Coordination::Models::Event)
                        raise ArgumentError,
                              "expected an action-event object, got #{object}. "\
                              "Acceptable events need to be created from e.g. "\
                              "actions by calling #task(action).my_event"
                    end

                    object
                end

                # Declare that this fault response table should be active as long as
                # this coordination model is
                def use_fault_response_table(table_model, arguments = {})
                    arguments = table_model.validate_arguments(arguments)
                    used_fault_response_tables << [table_model, arguments]
                end
            end
        end
    end
end
