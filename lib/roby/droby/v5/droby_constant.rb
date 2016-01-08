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

                @@valid_constants = Hash.new
                def self.valid_constants; @@valid_constants end
                def to_s; "#<dRoby:Constant #{name}>" end

                # Generic implementation of the constant-dumping method. This is to
                # be included in all kind of classes which should be dumped by their
                # constant name (for intance Relations::Graph).
                module Dump
                    # Returns a DRobyConstant object which references +self+. It
                    # checks that +self+ can actually be referenced locally by
                    # calling <tt>constant(name)</tt>, or raises ArgumentError if
                    # it is not the case.
                    def droby_dump(dest)
                        unless DRobyConstant.valid_constants[self]
                            begin
                                if name && (constant(name) == self)
                                    return(DRobyConstant.valid_constants[self] = DRobyConstant.new(name))
                                end
                            rescue Exception => e
                            end

                            Roby.info "could not resolve constant name for #{self}"
                            Roby.log_pp(e, Roby, :warn)
                            raise ArgumentError, "cannot resolve constant name for #{self}"
                        end
                        DRobyConstant.valid_constants[self]
                    end
                end

                # The constant name
                attr_reader :name
                def initialize(name); @name = name end
                # Returns the local object which can be referenced by this name, or
                # raises ArgumentError.
                def proxy(peer); constant(name) end
            end
        end
    end
end


