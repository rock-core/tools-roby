module Roby
    module DRoby
        module V5
            # Dumps a class and its ancestry
            #
            # Use {ClassDumper} to add the corresponding standard {#droby_dump}
            class DRobyClass
                # The class name
                attr_reader :name
                # The known siblings for this class
                attr_reader :remote_siblings
                # The class superclass
                attr_reader :superclass

                # Initialize a DRobyModel object with the given set of ancestors
                def initialize(name, remote_siblings, superclass)
                    @name = name
                    @remote_siblings = remote_siblings
                    @superclass  = superclass
                end

                # Returns a local Class object to match this class
                def proxy(peer)
                    # We have to manually call find_local_model here as it
                    # resolves classes by name as well as by ID
                    if m = peer.find_local_model(self)
                        return m
                    elsif !superclass # this class was supposed to be present
                        raise NoLocalObject, "cannot find local class #{name} as expected by the protocol"
                    else
                        name = self.name
                        local_class = Class.new(peer.local_model(superclass))
                        if name
                            local_class.singleton_class.class_eval do
                                define_method(:name) { name }
                            end
                        end
                        peer.register_model(local_class, remote_siblings)
                        local_class
                    end
                end
            end
        end
    end
end
