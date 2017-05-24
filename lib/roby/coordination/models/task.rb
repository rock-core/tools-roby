module Roby
    module Coordination
        module Models
            # A model-level coordination task
            #
            # Coordination models are built using instances of
            # {Coordination::Models::Task} (or its subclasses). When they get
            # instanciated into actual coordination objects, these are uniquely
            # associated with instances of {Coordination::Task} (or its
            # subclasses).
            #
            # This class is the base class for all model-level coordination
            # tasks. It is typed (i.e. we know the Roby task model that it
            # represents) and optionally has a name.
            class Task
                # The underlying Roby task model
                #
                # If it responds to {#find_child}, the coordination task model
                # will allow to validate the task's own children.
                #
                # @return [Model<Roby::Task>] the Roby task model, as a subclass
                #   of Roby::Task
                attr_accessor :model

                # The task name
                #
                # @return [nil,String]
                attr_accessor :name

                # Creates this model-level coordination task to represent a
                # given Roby task model
                #
                # @param [Model<Roby::Task>] model the Roby task model, which is
                #   either Roby::Task or one of its subclasses
                def initialize(model)
                    @model = model
                end

                # Create a new coordination task based on a different
                # coordination model
                def rebind(coordination_model)
                    dup
                end

                # @api private
                #
                # Used in {Base#rebind} to update the internal relationships
                # between coordination tasks
                def map_tasks(mapping)
                end

                # Returns an instance-level coordination task that can be used
                # to represent self
                #
                # It is delegated to the task model, as the actual class that is
                # used to represent self in a coordination object might depend
                # on the class of the model-level coordination task.
                #
                # @return [Coordination::Task]
                def new(execution_context)
                    Coordination::Task.new(execution_context, self)
                end

                # Tests if this task has a given event
                #
                # @param [String,Symbol] event_name the event name
                # @return [Boolean] true if the event is an event of self, and
                #   false otherwise
                def has_event?(event_name)
                    if model && model.respond_to?(:find_event)
                        model.find_event(event_name.to_sym)
                    else true
                    end
                end

                # Returns an model-level coordination event that can be used to
                # represent an event on this task
                #
                # @param [String,Symbol] event_name the event name
                # @return [Coordination::Models::Event] the event object, or nil
                #   if the event does not exist
                def find_event(event_name)
                    if has_event?(event_name)
                        return Event.new(self, event_name)
                    end
                end

                # Test if this coordination task can tell us something about the
                # models of its children
                #
                # It uses the presence or absence of a #find_child method on
                # {#model} to determine it.
                #
                # @return [Boolean] true if {#has_child?} and
                #   {#find_child_model} can return meaningful information.
                def can_resolve_child_models?
                    model && model.respond_to?(:find_child)
                end

                # Tests if this task has a child with the given role
                #
                # It always returns true if {#model} does not allow us to
                # resolve children. The rationale is that these methods are used
                # to type-validate tasks in e.g. action state machines and we
                # need to simply be permissive if the models does not allow us
                # to validate anything. Use {#can_resolve_child_models?} to know
                # whether validation is meaningful.
                #
                # @return [Boolean] true if the task has a child with the given
                #   role, or if {#model} does not allow to do any validation.
                def has_child?(role)
                    find_child_model(role) ||
                        !can_resolve_child_models?
                end

                # Returns the model of a given child of this task
                #
                # It always returns Roby::Task if {#model} does not allow us to
                # resolve children. The rationale is that these methods are used
                # to type-validate tasks in e.g. action state machines and we
                # need to simply be permissive if the models does not allow us
                # to validate anything. Use {#can_resolve_child_models?} to know
                # whether validation is meaningful.
                #
                # @return [Model<Roby::Task>,nil] the child's model, or nil if
                #   the child does not exist.
                def find_child_model(role)
                    if can_resolve_child_models?
                        model.find_child(role)
                    end
                end

                # Returns a representation of this task's child that can be used
                # in a coordination model
                #
                # @param [String,Symbol] role the child's role
                # @param [nil,Model<Roby::Task>] child_model the child's model.
                #   This can be set to either overwrite what is known to Roby
                #   (i.e. overwrite what {#model} announces), or to give
                #   information that {#model} does not have in case
                #   {#can_resolve_child_models?} returns false
                # @return [Coordination::Models::Child,nil] the child object, or
                #   nil if there is no such child on self
                def find_child(role, child_model = nil)
                    if has_child?(role)
                        return Child.new(self, role, child_model || find_child_model(role))
                    end
                end

                def find_through_method_missing(m, args)
                    MetaRuby::DSLs.find_through_method_missing(
                        self, m, args,
                        '_event' => :find_event,
                        '_child' => :find_child) ||
                        super
                end

                def has_through_method_missing?(m)
                    MetaRuby::DSLs.has_through_method_missing?(
                        self, m,
                        '_event' => :has_event?,
                        '_child' => :has_child?) ||
                        super
                end

                include MetaRuby::DSLs::FindThroughMethodMissing

                def to_coordination_task(task_model = Roby::Task)
                    self
                end

                # This method must be overloaded in the tasks that will be
                # actually used in the coordination primitives
                def instanciate(plan, variables = Hash.new)
                    raise NotImplementedError, "must reimplement #instanciate in the task objects used in coordination primitives"
                end

                def setup_instanciated_task(coordination_context, task, arguments = Hash.new)
                end
            end
        end
    end
end

