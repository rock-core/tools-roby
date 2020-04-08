# frozen_string_literal: true

class Module
    # Declare that +proxy_klass+ should be used to wrap objects of +real_klass+.
    # Order matters: if more than one wrapping matches, we will use the one
    # defined last.
    def proxy_for(real_klass)
        Roby::Transaction::Proxying.define_proxying_module(self, real_klass)
    end
end

module Roby
    # In transactions, we do not manipulate plan objects like Task and EventGenerator directly,
    # but through proxies which make sure that nothing forbidden is done
    #
    # The Proxy module define base functionalities for these proxy objects
    class Transaction < Plan
        module Proxying
            module Cache
                # The module used to transform proxies into call forwarder at commit
                # time
                #
                # It is initialized and used by
                # {Transaction::Proxying#forwarder_module_for}
                #
                # @return [Module,nil]
                attr_accessor :transaction_forwarder_module

                # The full module used to build transaction proxies for objects of this
                # model
                #
                # It is initialized and used by
                # {Transaction::Proxying#proxying_module_for}
                #
                # @return [Module,nil]
                attr_accessor :transaction_proxy_module
            end

            @@proxy_for = {}

            def to_s
                "tProxy(#{__getobj__})"
            end

            def self.define_proxying_module(proxying_module, mod)
                @@proxy_for[mod] = proxying_module
                nil
            end

            # Returns the proxying module for +object+
            def self.proxying_module_for(klass)
                if proxying_module = klass.transaction_proxy_module
                    return proxying_module
                end

                modules = klass.ancestors.map do |ancestor|
                    if mod_proxy = @@proxy_for[ancestor]
                        mod_proxy
                    end
                end.compact
                modules << Transaction::Proxying

                proxying_module = Module.new
                modules.reverse.each do |mod|
                    proxying_module.include mod
                end
                klass.transaction_proxy_module = proxying_module
            end

            def self.create_forwarder_module(methods)
                Module.new do
                    attr_accessor :__getobj__
                    def transaction_proxy?
                        true
                    end
                    methods.each do |name|
                        next if name =~ /^__.*__$/
                        next if name == :object_id

                        define_method(name) do |*args, &block|
                            __getobj__.send(name, *args, &block)
                        end
                    end
                end
            end

            # Returns a module that, when used to extend an object, will forward all
            # the calls to the object's @__getobj__
            def self.forwarder_module_for(klass)
                klass.transaction_forwarder_module ||=
                    create_forwarder_module(klass.instance_methods(true))
            end

            attr_reader :__getobj__

            def transaction_proxy?
                true
            end

            def setup_proxy(object, plan)
                @__getobj__ = object
            end

            alias == eql?

            def pretty_print(pp)
                if plan
                    plan.disable_proxying do
                        pp.text "TProxy:"
                        __getobj__.pretty_print(pp)
                    end
                else super
                end
            end

            def proxying?
                plan&.proxying?
            end

            # True if +peer+ has a representation of this object
            #
            # In the case of transaction proxies, we know they have siblings if the
            # transaction is present on the other peer.
            def has_sibling?(peer)
                plan.has_sibling?(peer)
            end
        end
    end
end
