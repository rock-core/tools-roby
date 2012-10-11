class Class
    # Implementation of a conversion to StateVariableModel
    #
    # It makes it possible to use a class to initialize a state leaf model with
    #
    #   state.model.path.to.value = MyClass
    def to_state_variable_model(field, name)
        model = Roby::StateVariableModel.new(field, name)
        model.type = self
        return model
    end
end

module Roby
    # Representation of a leaf in the state model
    class StateVariableModel
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

        def to_state_variable_model(field, name)
            result = dup
            result.field = field
            result.name = name
            result
        end
    end

    # Representation of a level in the state model
    class StateModel
        include ExtendedStruct

        # Returns the superclass, i.e. the state model this is a refinement on
        attr_reader :superclass

        def __rebind(object)
            if !__root?
                raise ArgumentError, "cannot rebind a non-root state model"
            else @__object = object
            end
        end

        # Returns the task model this state model applies on
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
                if result.kind_of?(StateSpace)
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
                superclass.each do |name, value|
                    if !@members.has_key?(name)
                        yield(name, value)
                    end
                end
            end
        end

        def initialize(super_or_obj = nil, attach_to = nil, attach_name = nil)
            if !super_or_obj || super_or_obj.kind_of?(StateModel)
                @__object = nil
                @superclass = super_or_obj
            else
                @__object = super_or_obj
                if @__object.respond_to?(:superclass) && @__object.superclass.respond_to?(:state)
                    @superclass = super_or_obj.superclass.state
                end
            end

            initialize_extended_struct(StateModel, attach_to, attach_name)
            global_filter do |name, value|
                if value.respond_to?(:to_state_variable_model)
                    value.to_state_variable_model(self, name)
                else
                    raise ArgumentError, "cannot set #{value} on #{name} in a state model. Only allowed values are StateVariableModel, and values that respond to #to_state_variable_model"
                end
            end
        end

        # This methods iterates over the state model, and for each state
        # variable for which a data source model is provided, create the
        # corresponding data source by calling #bind
        def resolve_data_sources(object, state)
            each_member do |name, field|
                if field.respond_to?(:data_source)
                    state.data_sources.__set(name, field.data_source.bind(object, state))
                else
                    field.resolve_data_sources(object, state.__get(name, true))
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
            @data_sources
        end

        def initialize(attach_to_or_model = nil, attach_name = nil)
            if attach_name
                attach_to(attach_to_or_model, attach_name)
            else
                @model = attach_to_or_model
                attach_to_or_model = nil
                @last_known = StateLastValueField.new
                @data_sources = StateDataSourceField.new
            end

            initialize_extended_struct(StateField, attach_to_or_model, attach_name)
            attach

            if model
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
        end

        def attach_to(parent, name)
            super
            @model = if parent.model
                         parent.model.get(name)
                     end
            @last_known = StateLastValueField.new(parent.last_known, name)
            @last_known.attach
            @data_sources = StateDataSourceField.new(parent.data_sources, name)
            @data_sources.attach
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
        #
        # It only allows writing to state variables
        def __set(name, value)
            if model && !model.get(name).kind_of?(StateVariableModel)
                raise ArgumentError, "#{name} is not a state variable on #{self}"
            end
            super
        end

        # Reimplemented from ExtendedStruct
        #
        # It disables automatic substruct creation. The reason is that the model
        # does it for us.
        def __get(name, create_substruct = true)
            if model || data_sources.get(name)
                # We never automatically create levels as the model should tell us
                # what we want
                create_substruct = false
            end
            return super(name, create_substruct)
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

        # Prepares the state structure using the provided model. In practice, it
        # creates all the sublevels declared in the model
        def initialize_from_model
            model.each_member do |name, field|
                case field
                when StateVariableModel
                    # Don't do anything here, as we don't know which values to
                    # set
                else
                    @members[name] = StateField.new(self, name)
                    @members[name].initialize_from_model
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
    class StateSpace < StateField
	def initialize(model = nil)
            @exported_fields = nil
	    super(model, nil)
            if model
                initialize_from_model
            end
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
end
