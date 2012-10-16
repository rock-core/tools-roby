module Roby
    module ExtendedStructModel
	include ExtendedStruct

        # Returns the superclass, i.e. the state model this is a refinement on
        attr_reader :superclass

        def __rebind(object)
            if !__root?
                raise ArgumentError, "cannot rebind a non-root model"
            else @__object = object
            end
        end

        # Returns the task model this goal model applies on
        def __object
            if !__root?
                __root.__object
            else
                @__object
            end
        end

        def __get(name, create_substruct = true, &update)
            if result = super(name, false, &update)
                return result
            elsif superclass && (result = superclass.__get(name, false, &update))
                if result.kind_of?(ExtendedStructModel)
                    return super(name, true, &update)
                else return result
                end
            elsif create_substruct
                return super
            end
        end

        def __respond_to__(name)
            super || (superclass.__respond_to__(name) if superclass)
        end

        def create_subfield(name)
            if superclass
                children_class.new(superclass.get(name), self, name)
            else
                children_class.new(nil, self, name)
            end
        end

        def each_member(&block)
            super(&block)
            if superclass
                superclass.each_member do |name, value|
                    if !@members.has_key?(name)
                        yield(name, value)
                    end
                end
            end
        end

        def initialize_extended_struct(child_class, super_or_obj = nil, attach_to = nil, attach_name = nil)
            if !super_or_obj || super_or_obj.kind_of?(StateModel)
                @__object = nil
                @superclass = super_or_obj
            else
                @__object = super_or_obj
                if @__object.respond_to?(:superclass) && @__object.superclass.respond_to?(:state)
                    @superclass = super_or_obj.superclass.state
                end
            end

            super(child_class, attach_to, attach_name)
        end
    end
end
