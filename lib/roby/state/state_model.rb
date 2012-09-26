class Class
    def to_state_leaf_model
        model = Roby::StateLeafModel.new
        model.type = self
        return model
    end
end

module Roby
    # Representation of a leaf in the state model
    class StateLeafModel
        # Returns the type of this field. nil means any type. It is matched
        # against values using #===
        attr_accessor :type

        # Returns a data source for that field. The data source must answer to
        # #read, and #read must return either a value if the source is active
        # and has one, or nil if the source is currently inactive
        attr_accessor :source
    end

    # Representation of a level in the state model
    class StateFieldModel
        include ExtendedStruct

        def initialize(attach_to = nil, attach_name = nil)
            initialize_extended_struct(StateFieldModel, attach_to, attach_name)
            global_filter do |name, value|
                if value.respond_to?(:to_state_leaf_model)
                    value.to_state_leaf_model
                else
                    raise ArgumentError, "cannot set #{value} on #{name} in a state model. Only allowed values are StateFieldModel, and values that respond to #to_state_field_model"
                end
            end
        end
    end

    # Representation of the last known state
    class StateLastValueField
        include ExtendedStruct
        def initialize(attach_to = nil, attach_name = nil)
            initialize_extended_struct(StateLastValueField, attach_to, attach_name)
        end

        def method_missing(name, *args, &block)
            if name =~ /=$/
                raise ArgumentError, "cannot write to a StateLastValueField object"
            end
            return super
        end
    end

    # Representation of the data sources in the state
    class StateDataSourceField
        include ExtendedStruct
        def initialize(attach_to = nil, attach_name = nil)
            initialize_extended_struct(StateDataSourceField, attach_to, attach_name)
        end
    end

    # Representation of a level in the current state
    class StateField
        include ExtendedStruct

        # Returns the model of this field. It is also a StateField, but all the
        # leafs on this StateField are StateFieldModel instances.
        def model
            attach
            @model
        end

        # Returns the last known value for this field
        def last_known
            attach
            @last_known
        end

        # The actual data sources for the members of this field. Data source
        # models are available under model.field_name.data_source
        def data_sources
            attach
            @data_sources
        end

        def initialize(attach_to = nil, attach_name = nil)
            if attach_to
                @model = attach_to.model.__get(attach_name)
                @last_known = attach_to.last_known.__get(attach_name)
                @data_sources = attach_to.data_sources.__get(attach_name)
            else
                @model = StateFieldModel.new
                @last_known = StateLastValueField.new
                @data_sources = StateDataSourceField.new
            end

            initialize_extended_struct(StateField, attach_to, attach_name)
            global_filter do |name, value|
                if (field_model = model.get(name)) && (field_type = field_model.type)
                    if !(field_type === value)
                        raise ArgumentError, "field #{field_name} is expected to have values of type #{expected_type.name}, #{value} is of type #{value.class}"
                    end
                    value
                end
                value
            end
        end

        def create_subfield(name)
            children_class.new(self, name)
        end

        def attach
            @model.attach
            @last_known.attach
            @data_sources.attach
            super
        end

        def method_missing(name, *args)
            if name.to_s =~ /(.*)=$/
                if data_source = data_sources.get($1)
                    raise ArgumentError, "cannot explicitely set a field for which a data source exists"
                end
            end
            super
        end


        def __get(name, create_substruct = true)
            name = name.to_s
            if field_model = model.get(name)
                if field_model.kind_of?(StateLeafModel) && field_model.type
                    # A type is specified, don't do automatic struct creation
                    return super(name, false)
                end
            end
            if (data_source = data_sources.get(name)) && !data_source.kind_of?(StateDataSourceField)
                # A data source is specified, don't do automatic struct creation
                # either
                return super(name, false)
            end

            return super
        end

        # Read each subfield that have a source, and update both their
        # last_known and current value.
        def read
            data_sources.each_member do |field_name, field_source|
                new_value = field_source.read
                __set(field_name, new_value)
                if new_value
                    last_known.__set(field_name, new_value)
                end
            end
        end
    end

    class StateModel < StateField
	def initialize
            @exported_fields = nil
	    super
	end

        def export_none
            @exported_fields = Set.new
        end

        def export_all
            @exported_fields = nil
        end

	def export(*names)
            @exported_fields ||= Set.new
	    @exported_fields.merge names.map { |n| n.to_s }.to_set
	end

	def _dump(lvl = -1)
            if !@exported_fields
                super
            else
                marshalled_members = @exported_fields.map do |name|
                    value = @members[name]
                    [name, Marshal.dump(value)] rescue nil
                end
                marshalled_members.compact!
                Marshal.dump([marshalled_members, @aliases])
            end
	end

	def deep_copy
	    exported_fields, @exported_fields = @exported_fields, Set.new
	    Marshal.load(Marshal.dump(self))
	ensure
	    @exported_fields = exported_fields
	end

	def testing?; Roby.app.testing? end
	def simulation?; Roby.app.simulation? end
    end
    StateSpace = StateModel
end
