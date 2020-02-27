module Roby
    class Transaction
        module PlanObjectProxy
            proxy_for PlanObject

            def setup_proxy(object, plan)
                super(object, plan)
                @finalization_handlers.clear
            end

            # Uses the +enum+ method on this proxy and on the proxied object to get
            # a set of objects related to this one in both the plan and the
            # transaction.
            # 
            # The block is then given a plan_object => transaction_object hash, the
            # relation which is being considered, the set of new relations (the
            # relations that are in the transaction but not in the plan) and the
            # set of deleted relation (relations that are in the plan but not in
            # the transaction)
            def partition_new_old_relations(enum, include_proxies: true) # :yield:
                trsc_objects = Hash.new
                each_relation do |rel|
                    trsc_others = Set.new
                    send(enum, rel) do |obj|
                        plan_object =
                            if obj.transaction_proxy?
                                next if !include_proxies
                                obj.__getobj__
                            else obj
                            end

                        trsc_objects[plan_object] = obj
                        trsc_others << plan_object
                    end

                    plan_others = Set.new
                    if include_proxies
                        __getobj__.send(enum, rel) do |child|
                            if plan[child, create: false]
                                plan_others << child
                            end
                        end
                    end

                    new = (trsc_others - plan_others)
                    existing = (trsc_others - new)
                    del = (plan_others - trsc_others)

                    yield(trsc_objects, rel, new, del, existing)
                end
            end

            # Commits the modifications of this proxy. It copies the relations of
            # the proxy on the proxied object
            def commit_transaction
                # The relation graph handling is a bit tricky. We resolve the graphs
                # exclusively using self (NOT other) because if 'other' was a new
                # task, it has been already moved to the new plan (and its relation
                # graph resolution is using the new plan's new graphs already)


                super

                if @executable != __getobj__.instance_variable_get(:@executable)
                    __getobj__.executable = @executable
                end

                finalization_handlers.each do |handler|
                    __getobj__.when_finalized(handler.as_options, &handler.block)
                end
            end

            def initialize_replacement(object, &block)
                # Apply recursively all finalization handlers of this (proxied)
                # object to the object event
                #
                # We have to look at all levels as, in transactions, the "handlers"
                # set only contains new handlers
                real_object = self
                while real_object.transaction_proxy?
                    real_object = real_object.__getobj__
                    real_object.finalization_handlers.each do |h|
                        if h.copy_on_replace?
                            object ||= yield
                            object.when_finalized(h.as_options, &h.block)
                        end
                    end
                end

                if object
                    super(object)
                else super(nil, &block)
                end
            end
        end
    end
end


