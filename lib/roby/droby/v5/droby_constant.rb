# frozen_string_literal: true

module Roby
    module DRoby
        module V5
            # Dumps a constant by using its name. On reload, #proxy searches for a
            # constant with the same name, and raises ArgumentError if none exists.
            #
            # @example dump instances of a class that are registered as constants
            #   class Klass
            #     include DRobyConstant::Dump
            #   end
            #   # Obj can pass through droby
            #   Obj = Klass.new
            #
            # @example dump classes. You usually would prefer using {DRobyModel}
            #   # Klass can pass through droby
            #   class Klass
            #     extend DRobyConstant::Dump
            #   end
            class DRobyConstant
                def self.clear_cache
                    @@valid_constants.clear
                end

                @@valid_constants = {}
                def self.valid_constants
                    @@valid_constants
                end

                def to_s
                    "#<dRoby:Constant #{name}>"
                end

                # Generic implementation of the constant-dumping method. This is to
                # be included in all kind of classes which should be dumped by their
                # constant name (for intance Relations::Graph).
                module Dump
                    class ConstantResolutionFailed < RuntimeError; end
                    class MismatchingLocalConstant < ConstantResolutionFailed; end

                    # Returns a DRobyConstant object which references +self+. It
                    # checks that +self+ can actually be referenced locally by
                    # calling <tt>constant(name)</tt>, or raises ArgumentError if
                    # it is not the case.
                    def droby_dump(peer)
                        if constant = DRobyConstant.valid_constants[self]
                            return constant
                        elsif !name
                            raise ConstantResolutionFailed, "#{self}#name returned nil"
                        end

                        name = "::#{self.name}"

                        begin
                            local_constant = constant(name)
                        rescue Exception => e
                            Roby.warn "could not resolve constant name for #{self}"
                            Roby.log_exception(e, Roby, :warn)
                            raise ConstantResolutionFailed, "cannot resolve constant name for #{self}"
                        end

                        if local_constant == self
                            DRobyConstant.valid_constants[self] = DRobyConstant.new(name, peer.known_siblings_for(self))
                        else
                            raise MismatchingLocalConstant,
                                  "got DRobyConstant whose name '#{name}' resolves "\
                                  "to #{local_constant}(#{local_constant.class}), "\
                                  "not itself (#{self})"
                        end
                    end

                    def droby_marshallable?
                        true
                    end
                end

                attr_reader :remote_siblings

                # The constant name
                attr_reader :name

                def initialize(name, remote_siblings = {})
                    @name = name
                    @remote_siblings = remote_siblings
                end

                # Returns the local object which can be referenced by this name, or
                # raises ArgumentError.
                def proxy(peer)
                    constant(name)
                end
            end
        end
    end
end
