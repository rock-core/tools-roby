module Roby
    module Actions
        # The representation of an action, as a model and arguments
        class Action
            # The action model
            # @return [Models::Action]
            attr_accessor :model
            # The action arguments
            # @return [Hash]
            attr_reader :arguments

            def initialize(model, arguments = Hash.new)
                @model, @arguments = model, arguments
            end

            def name
                model.name
            end

            # The task model returned by this action
            def returned_type
                model.returned_type
            end

            # Returns a plan pattern that would deploy this action in the plan
            # @return [Roby::Task] the task, with a planning task of type
            #   {Actions::Task}
            def as_plan(arguments = Hash.new)
                model.plan_pattern(self.arguments.merge(arguments))
            end

            def rebind(action_interface_model)
                result = dup
                result.model = result.model.rebind(action_interface_model)
                result
            end

            # Deploys this action on the given plan
            def instanciate(plan, arguments = Hash.new)
                model.instanciate(plan, self.arguments.merge(arguments))
            end

            def to_s
                "#{model}(#{arguments.map { |k,v| "#{k} => #{v}" }.sort.join(", ")})"
            end

            def to_coordination_task(task_model = Roby::Task)
                Coordination::Models::TaskFromAction.new(self)
            end

            # Returns the coordination model that defines the underlying action
            # 
            # @return (see Models::Action#to_coordination_model)
            # @raise (see Models::Action#to_coordination_model)
            def to_coordination_model
                model.to_coordination_model
            end

            def droby_dump(peer)
                result = dup
                result.droby_dump!(peer)
                result
            end

            def droby_dump!(peer)
                @model = model.droby_dump(peer)
                @arguments = arguments.droby_dump(peer)
            end

            def proxy(peer)
                result = dup
                result.proxy!(peer)
                result
            end

            def proxy!(peer)
                @model = peer.local_object(model)
                @arguments = peer.local_object(arguments)
            end

            def to_action
                self
            end
        end
    end
end
