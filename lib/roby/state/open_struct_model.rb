# frozen_string_literal: true

module Roby
    class OpenStructModel < OpenStruct
        # Returns the superclass, i.e. the state model this is a refinement on
        attr_reader :superclass

        def __get(name, create_substruct = true, &update)
            if (result = super(name, false, &update))
                result
            elsif superclass && (result = superclass.__get(name, false, &update))
                if result.kind_of?(OpenStructModel)
                    super(name, true, &update)
                else
                    result
                end
            elsif create_substruct
                super
            end
        end

        def __respond_to__(name)
            super || superclass&.__respond_to__(name)
        end

        def create_subfield(name)
            if superclass
                self.class.new(superclass.get(name), self, name)
            else
                self.class.new(nil, self, name)
            end
        end

        def each_member(&block)
            super(&block)
            superclass&.each_member do |name, value|
                unless @members.has_key?(name)
                    yield(name, value)
                end
            end
        end

        def initialize(super_or_obj = nil, attach_to = nil, attach_name = nil)
            @superclass = super_or_obj
            super(nil, attach_to, attach_name)
        end

        # Base implementation for "leaf" values in an extended struct model
        class Variable
            # The name of this leaf in its parent field
            attr_accessor :name

            # The parent field
            attr_accessor :field

            def initialize(field = nil, name = nil)
                @field, @name = field, name
            end

            # Returns the full path of this leaf w.r.t. the root of the state
            # structure
            def path
                path = field.path.dup
                path << name
                path
            end
        end
    end
end
