# frozen_string_literal: true

module Roby
    module Interface
        module REST
            module Helpers
                # The underlying Roby interface
                #
                # @return [Roby::Interface]
                def interface
                    return @interface if @interface

                    i = env.fetch("roby.interface")
                    @interface = roby_thread_protection(i) do
                        i.inside_control?
                    end
                end

                # The underlying Roby app
                #
                # @return [Roby::Application]
                def roby_app
                    return @roby_app if @roby_app

                    i = env.fetch("roby.interface")
                    @roby_app = roby_thread_protection(i.app) do
                        i.execution_engine.inside_control?
                    end
                end

                # @api private
                #
                # Wrap `object` within a proxy that validate that calls are made inside
                # the Roby execution thread
                #
                # The wrapping is disabled by default. Need to set
                # Conf.roby.rest_thread_protection to true to enable. It is always
                # disabled in tests because of interference with comparisons (e.g.
                # flexmock or assert_equal)
                def roby_thread_protection(object, &block)
                    if !Roby.app.testing? && Conf.roby.rest_thread_protection?
                        ThreadProtectionProxy.new(i.app, &block)
                    else
                        object
                    end
                end

                # The underlying Roby plan
                #
                # @return [Roby::ExecutablePlan]
                def roby_plan
                    return @roby_plan if @roby_plan

                    i = env.fetch("roby.interface")
                    @roby_plan = roby_thread_protection(i.plan) do
                        i.execution_engine.inside_control?
                    end
                end

                # A permanent storage hash
                def roby_storage
                    env.fetch("roby.storage")
                end

                # The underlying Roby execution engine
                #
                # @return [Roby::ExecutablePlan]
                def execution_engine
                    return @execution_engine if @execution_engine

                    i = env.fetch("roby.interface")
                    @roby_plan = roby_thread_protection(i.execution_engine) do
                        i.execution_engine.inside_control?
                    end
                end

                # Execute a block in a context synchronzied with the engine
                def roby_execute(&block)
                    i = env.fetch("roby.interface")
                    i.execution_engine.execute(&block)
                end

                # @deprecated use {#roby_execute} instead
                def execute(&block)
                    return super unless block_given?

                    Roby.warn_deprecated "Helpers#execute is deprecated, "\
                                         "use #roby_execute instead"
                    roby_execute(&block)
                end

                # @api private
                #
                # (Mostly) transparent proxy that validates that all calls are
                # within a given thread
                #
                # The class calls the block given to its constructor for each call,
                # and will raise if the block returns false
                #
                # @see Helpers#roby_thread_protection
                class ThreadProtectionProxy < BasicObject
                    def initialize(object, &in_thread)
                        @object = object
                        @in_thread = in_thread
                    end

                    def respond_to_missing?(name, *)
                        @object.respond_to?(name)
                    end

                    def inspect
                        "ThreadProtectionProxy(#{super})"
                    end

                    def to_s
                        "ThreadProtectionProxy(#{super})"
                    end

                    def method_missing(name, *args, **kw, &block)
                        unless @in_thread.call
                            $stderr.puts "wrong thread in call to #{@object}"
                            $stderr.puts ::Kernel.caller.join("\n  ")
                            ::Kernel.raise ::ThreadError,
                                           "wrong thread in call to #{@object}"
                        end

                        @object.send(name, *args, **kw, &block)
                    end
                end
            end
        end
    end
end
