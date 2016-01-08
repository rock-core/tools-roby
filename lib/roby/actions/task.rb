module Roby
    module Actions
        # A task that calls an action interface to generate a plan
        class Task < Roby::Task
            terminates

            provides Roby::Interface::Job

            # Once the task has been started, this is the interface object that
            # is being used / has been used to generate the action in the plan
            # @return [Interface]
            attr_reader :action_interface
            # Once the task has been started, this is the transaction object that
            # is being used / has been used to generate before committing in the
            # plan
            # @return [Transaction]
            attr_reader :transaction

            # The action itself
            # @return [Models::Action]
            argument :action_model
            # The arguments for the action method
            # @return [Hash]
            argument :action_arguments, default: Hash.new

            # The model of the roby task that is going to represent the action
            # in the plan
            # @return [Model<Roby::Task>] 
            def planned_model
                action_model.returned_task_type
            end

            # The action interface model used by this planner
            # @return [Model<Interface>]
            def action_interface_model
                action_model.action_interface_model
            end
                
            def job_name
                formatted_arguments = (action_arguments || Hash.new).map do |k, v|
                    "#{k} => #{v}"
                end.join(", ")
                "#{action_model}(#{formatted_arguments})"
            end

            def to_s
                if action_model
                    "#{super}[#{action_interface_model}:#{action_model}](#{action_arguments}) -> #{action_model.returned_type}"
                else "#{super}"
                end
            end

            def planned_task
                if success? || result
                    result
                elsif task = planned_tasks.find { true }
                    task
                elsif pending?
                    task = planned_model.new
                    task.planned_by self
                    task.abstract = true
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
                start_event.emit

                if owners.size > 1
                    @transaction = Distributed::Transaction.new(plan)
                    owners.each do |peer|
                        transaction.add_owner peer
                    end
                else
                    @transaction = Transaction.new(plan)
                end
            end

            poll do
                @action_interface = action_interface_model.new(transaction)
                result_task = action_model.run(action_interface, action_arguments)

                # Don't replace the planning task with ourselves if the
                # transaction specifies another planning task
                if new_planning_task = result_task.planning_task
                    new_planning_task.job_id ||= job_id
                else
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
                success_event.emit
            end

            on :failed do |event|
                transaction.discard_transaction
            end
        end
    end
end

