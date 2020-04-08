# frozen_string_literal: true

module Roby
    class Transaction
        # Transaction proxy for Roby::Task
        module TaskProxy
            proxy_for Task

            def to_s
                "tProxy(#{__getobj__.name})#{arguments}"
            end

            STATE_PREDICATES = %i[pending? running? finished? success? failed?].freeze

            STATE_PREDICATES.each do |predicate_name|
                attr_predicate predicate_name
            end

            # Create a new proxy representing +object+ in +transaction+
            def setup_proxy(object, transaction)
                super(object, transaction)

                @poll_handlers.clear
                @execute_handlers.clear

                @arguments = Roby::TaskArguments.new(self)
                if !bound_events.empty?
                    raise ArgumentError, "expected bound_events to be empty when setting the proxy up"
                end

                STATE_PREDICATES.each do |predicate_name|
                    instance_variable_set "@#{predicate_name[0..-2]}", object.send(predicate_name)
                end

                object.arguments.each do |key, value|
                    if value.kind_of?(Roby::PlanObject)
                        arguments.update!(key, transaction[value])
                    else
                        arguments.update!(key, value)
                    end
                end

                proxied_events = []
                events = object.each_event.to_a
                transaction.plan.each_event_relation_graph do |g|
                    next if !g.root_relation?

                    events.delete_if do |event|
                        should_proxy =
                            g.each_in_neighbour(event).any? { |e| !e.respond_to?(:task) || e.task != object } ||
                            g.each_out_neighbour(event).any? { |e| !e.respond_to?(:task) || e.task != object }
                        if should_proxy
                            proxied_events << event
                        end
                    end
                    break if events.empty?
                end
                proxied_events.each do |ev|
                    transaction.create_and_register_proxy_event(ev)
                end
            end

            def has_event?(name)
                super || __getobj__.has_event?(name)
            end

            def event(name)
                if ev = find_event(name)
                    ev
                else
                    ev = __getobj__.event(name)
                    bound_events[ev.symbol] = plan.create_and_register_proxy_event(ev)
                end
            end

            # Perform the operations needed for the commit to be successful.  In
            # practice, it updates the task arguments as needed.
            def commit_transaction
                super

                # Update the task arguments. The original
                # Roby::Task#commit_transaction has already translated the proxy
                # objects into real objects
                arguments.each do |key, value|
                    __getobj__.arguments.update!(key, value)
                end

                execute_handlers.each do |h|
                    __getobj__.execute(h.as_options, &h.block)
                end
                poll_handlers.each do |h|
                    __getobj__.poll(h.as_options, &h.block)
                end

                __getobj__.abstract = self.abstract?
                if @fullfilled_model
                    __getobj__.fullfilled_model = @fullfilled_model.dup
                end
                __getobj__.do_not_reuse if !@reusable
            end

            def initialize_replacement(task)
                super

                seen_events = bound_events.keys.to_set

                # Apply recursively all event handlers of this (proxied) task to
                # the new task
                #
                # We have to look at all levels as, in transactions, the "handlers"
                # set only contains new event handlers
                real_object = self
                while real_object.transaction_proxy?
                    real_object = real_object.__getobj__
                    real_object.execute_handlers.each do |h|
                        if h.copy_on_replace?
                            task.execute(h.as_options, &h.block)
                        end
                    end
                    real_object.poll_handlers.each do |h|
                        if h.copy_on_replace?
                            task.poll(h.as_options, &h.block)
                        end
                    end

                    # Do the same for all events that are not present at this level
                    # of the transaction
                    real_object.each_event do |event|
                        if !seen_events.include?(event.symbol)
                            event.initialize_replacement(nil) { task.event(event.symbol) }
                            seen_events << event.symbol
                        end
                    end
                end
            end
        end
    end
end
