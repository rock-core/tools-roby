class Class
    # Implementation of a conversion to StateLeafModel
    #
    # It makes it possible to use a class to initialize a state leaf model with
    #
    #   state.model.path.to.value = MyClass
    def to_state_leaf_model(field, name)
        model = Roby::StateLeafModel.new(field, name)
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

        # Returns a data source for that field
        #
        # At this level, the format data source is unspecified. It is meant to
        # be used by other mechanisms to fill the data_source tree in the state
        # object (this is the state model)
        attr_accessor :data_source

        # The name of this leaf in its parent field
        attr_accessor :name

        # The parent field
        attr_accessor :field

        def initialize(field, name)
            @field, @name = field, name
        end

        # Returns the full path of this leaf w.r.t. the root of the state
        # structure
        def path
            path = field.path.dup
            path << name
            path
        end

        def to_state_field_model(field, name)
            result = dup
            result.field = field
            result.name = name
            result
        end
    end

    # Representation of a level in the state model
    class StateFieldModel
        include ExtendedStruct

        # Returns the superclass, i.e. the state model this is a refinement on
        attr_reader :superclass

        # Returns the task model this state model applies on
        def task_model
            if !__root?
                __root.task_model
            else
                @task_model
            end
        end

        def __get(name, create_substruct = true, &update)
            if result = super(name, false, &update)
                return result
            elsif superclass && (result = superclass.__get(name, false, &update))
                return result
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
                superclass.each do |name, value|
                    if !@members.has_key?(name)
                        yield(name, value)
                    end
                end
            end
        end

        def initialize(superclass_or_task_model = nil, attach_to = nil, attach_name = nil)
            if !superclass_or_task_model || superclass_or_task_model.kind_of?(StateFieldModel)
                @task_model = nil
                @superclass = superclass_or_task_model
            else
                @task_model = superclass_or_task_model
                @superclass =
                    if task_model.superclass && task_model.superclass.respond_to?(:state)
                        task_model.superclass.state
                    end
            end

            initialize_extended_struct(StateFieldModel, attach_to, attach_name)
            global_filter do |name, value|
                if value.respond_to?(:to_state_leaf_model)
                    value.to_state_leaf_model(self, name)
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

        # Returns a structure that gives access to the models of the
        # members of this struct. I.e.
        #
        #   state.pose.model.position
        #   
        # is the model for state.pose.position
        #
        # Due to the use of open structures, one should always check for the
        # presence of the field first with
        #
        #   if state.pose.model.position?
        #      # do something with state.pose.model.position
        #   end
        #
        # Note that the models are accessible from any level, i.e.
        # state.model.pose.position is an equivalent of the above example.
        def model
            attach
            @model
        end

        # Returns a structure that gives access to the last known values for the
        # members of this struct. I.e.
        #
        #   state.pose.last_known.position
        #   
        # is the last value known for state.pose.position
        #
        # Note that the last known values are accessible from any level, i.e.
        # state.last_known.pose.position is an equivalent of the above example.
        def last_known
            attach
            @last_known
        end

        # Returns a structure that gives access to the data sources for the
        # members of this struct. I.e.
        #
        #   state.pose.data_sources.position
        #   
        # will give the data source for state.pose.position if there is one.
        #
        # Due to the use of open structures, one should always check for the
        # presence of the field first with
        #
        #   if state.pose.data_sources.position?
        #      # do something with state.pose.data_sources.position
        #   end
        #
        # Note that the models are accessible from any level, i.e.
        # state.model.pose.position is an equivalent of the above example.
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
                        raise ArgumentError, "field #{name} is expected to have values of type #{field_type.name}, #{value} is of type #{value.class}"
                    end
                    value
                end
                value
            end
        end

        # Reimplemented from ExtendedStruct
        def attach
            @model.attach
            @last_known.attach
            @data_sources.attach
            super
        end

        # Reimplemented from ExtendedStruct
        def method_missing(name, *args)
            if name.to_s =~ /(.*)=$/
                if data_source = data_sources.get($1)
                    raise ArgumentError, "cannot explicitely set a field for which a data source exists"
                end
            end
            super
        end

        # Reimplemented from ExtendedStruct
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

    # Implementation of the state representation at runtime.
    #
    # It gives access to three views to the state:
    #  * the current values are directly accessible from this state object
    #  * the last known value is stored in last_known.path.to.value
    #  * the state model is stored in model.path.to.value
    #  * the current data source for a state variable is stored in
    #    data_sources.path.to.value
    class StateModel < StateField
	def initialize
            @exported_fields = nil
	    super
	end

        # Declares that no state fields should be marshalled. The default is to
        # export everything
        #
        # It cancels any list of fields exported with #export
        #
        # See also #export_all and #export
        def export_none
            @exported_fields = Set.new
        end

        # Declares that all the state fields should be marshalled. This is the
        # default
        #
        # It cancels any list of fields exported with #export
        #
        # See also #export_none and #export
        def export_all
            @exported_fields = nil
        end

        # Declares that only the given names should be marshalled, instead of
        # marshalling every field. It is cumulative, i.e. if multiple calls to
        # #export follow each other then the fields get added to the list of
        # exported fields instead of replacing it.
        #
        # If #export_all has been called, a call to #export cancels it.
        #
        # See also #export_none and #export_all
	def export(*names)
            @exported_fields ||= Set.new
	    @exported_fields.merge names.map { |n| n.to_s }.to_set
	end

        # Implementation of marshalling with Ruby's Marshal
        #
        # Only the fields that can be marshalled will be saved. Any other field
        # will silently be ignored.
        #
        # Which fields get marshalled can be controlled with #export_all,
        # #export_none and #export. The default is to marshal all fields.
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
