module Roby
    module Actions
        # A task that calls an action interface to generate a plan
        class Task < Roby::Task
            attr_reader :planner, :transaction

            # The Interface class that should be used to generate the action
            # @return [Interface]
            argument :action_interface_model
            # The action itself
            # @return [Description]
            argument :action_description
            # The arguments for the action method
            # @return [Hash]
            argument :action_arguments, :default => Hash.new

            # The model of the roby task that is going to represent the action
            # in the plan
            def planned_model
                action_description.returns
            end

            def to_s
                "#{super}[#{interface_model}:#{action_description}](#{action_arguments}) -> #{action_description.returns}"
            end

            def planned_task
                if success? || result
                    result
                elsif task = planned_tasks.find { true }
                    task
                elsif pending?
                    task = planned_model.new
                    task.planned_by self
                    task.executable = false
                    task
                end
            end

            # The transaction in which we build the new plan. It gets committed on
            # success.
            attr_reader :transaction
            # The planner result. It is either an exception or a task object
            attr_reader :result

            # Starts planning
            event :start do |context|
                emit :start

                if owners.size != 1
                    @transaction = Distributed::Transaction.new(plan)
                    owners.each do |peer|
                        transaction.add_owner peer
                    end
                else
                    @transaction = Transaction.new(plan)
                end
            end

            poll do
                planner = action_interface_model.new(transaction)
                @result = action_description.execute(planner, action_arguments)

                # Don't replace the planning task with ourselves if the
                # transaction specifies another planning task
                if !result_task.planning_task
                    result_task.planned_by transaction[self]
                end

                if placeholder = planned_task
                    placeholder = transaction[placeholder]
                    transaction.replace(placeholder, result_task)
                    placeholder.remove_planning_task transaction[self]
                end

                # If the transaction is distributed, and is not proposed to all
                # owners, do it
                transaction.propose
                transaction.commit_transaction
                @result = result_task
            end
        end
    end
end

