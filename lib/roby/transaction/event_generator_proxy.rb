module Roby
    class Transaction
        module EventGeneratorProxy
            proxy_for EventGenerator
            
            def setup_proxy(object, plan)
                super(object, plan)
                @handlers.clear
                @unreachable_handlers.clear
                if object.controlable?
                    @command = method(:emit)
                end
            end

            def initialize_replacement(event)
                # Apply recursively all event handlers of this (proxied) event to
                # the new event
                #
                # We have to look at all levels as, in transactions, the "handlers"
                # set only contains new event handlers
                real_object = self
                while real_object.transaction_proxy?
                    real_object = real_object.__getobj__

                    real_object.handlers.each do |h|
                        if h.copy_on_replace?
                            event ||= yield
                            event.on(h.as_options, &h.block)
                        end
                    end
                    real_object.unreachable_handlers.each do |cancel, h|
                        if h.copy_on_replace?
                            event ||= yield
                            event.if_unreachable(cancel_at_emission: cancel, on_replace: :copy, &h.block)
                        end
                    end
                end

                if event
                    super(event)
                else super(nil, &Proc.new)
                end
            end

            def commit_transaction
                super

                handlers.each { |h| __getobj__.on(h.as_options, &h.block) }
                unreachable_handlers.each do |cancel, h|
                    on_replace = if h.copy_on_replace? then :copy
                                 else :drop
                                 end
                    __getobj__.if_unreachable(
                        cancel_at_emission: cancel,
                        on_replace: on_replace,
                        &h.block)
                end
            end
        end
    end
end


