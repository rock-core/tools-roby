# frozen_string_literal: true

class Class
    # Implementation of a conversion to StateVariableModel
    #
    # It makes it possible to use a class to initialize a state leaf model with
    #
    #   state.model.path.to.value = MyClass
    def to_state_variable_model(field, name)
        model = Roby::StateVariableModel.new(field, name)
        model.type = self
        model
    end
end

module Roby
    # Representation of a leaf in the state model
    class StateVariableModel < OpenStructModel::Variable
        # Returns the type of this field. nil means any type. It is matched
        # against values using #===
        attr_accessor :type

        # Returns a data source for that field
        #
        # At this level, the format data source is unspecified. It is meant to
        # be used by other mechanisms to fill the data_source tree in the state
        # object (this is the state model)
        attr_accessor :data_source

        def to_state_variable_model(field, name)
            result = dup
            result.field = field
            result.name = name
            result
        end
    end

    # Representation of a level in the state model
    class StateModel < OpenStructModel
        # Returns the superclass, i.e. the state model this is a refinement on
        attr_reader :superclass

        def to_s
            "#<StateModel:#{object_id} path=#{path.join('/')} "\
            "fields=#{@members.keys.sort.join(',')}>"
        end

        def initialize(super_or_obj = nil, attach_to = nil, attach_name = nil)
            super(super_or_obj, attach_to, attach_name)
            global_filter do |name, value|
                if value.respond_to?(:to_state_variable_model)
                    value.to_state_variable_model(self, name)
                else
                    raise ArgumentError,
                          "cannot set #{value} on #{name} in a state model. "\
                          "Only allowed values are StateVariableModel, and values "\
                          "that respond to #to_state_variable_model"
                end
            end
        end

        # This methods iterates over the state model, and for each state
        # variable for which a data source model is provided, create the
        # corresponding data source by calling #resolve
        def resolve_data_sources(object, state)
            each_member do |name, field|
                if field.respond_to?(:data_source)
                    state.data_sources.set(name, field.data_source.resolve(object))
                else
                    field.resolve_data_sources(object, state.__get(name, true))
                end
            end
        end
    end

    # Representation of the last known state
    class StateLastValueField < OpenStruct
        def method_missing(name, *args)
            if name =~ /=$/
                raise ArgumentError, "cannot write to a StateLastValueField object"
            end

            super
        end
    end

    # Representation of the data sources in the state
    class StateDataSourceField < OpenStruct
    end

    # Representation of a level in the current state
    class StateField < OpenStruct
        def to_s
            "#<StateField:#{object_id} path=#{path.join('/')} "\
            "fields=#{@members.keys.sort.join(',')}>"
        end

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
        attr_reader :model

        # Returns a structure that gives access to the last known values for the
        # members of this struct. I.e.
        #
        #   state.pose.last_known.position
        #
        # is the last value known for state.pose.position
        #
        # Note that the last known values are accessible from any level, i.e.
        # state.last_known.pose.position is an equivalent of the above example.
        attr_reader :last_known

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
        attr_reader :data_sources

        def initialize(model = nil, attach_to = nil, attach_name = nil)
            unless attach_to
                # We are root, initialize last_known and data_sources
                @last_known = StateLastValueField.new
                @data_sources = StateDataSourceField.new
            end

            super(model, attach_to, attach_name)

            install_type_checking_filter(model) if model
        end

        def install_type_checking_filter(model)
            # If we do have a model, verify that the assigned values match
            # the model's type
            global_filter do |name, value|
                field_model = model.get(name)
                field_type = field_model&.type

                if field_type && !(field_type === value)
                    raise ArgumentError,
                          "field #{name} is expected to have values of "\
                          "type #{field_type.name}, #{value} is of type "\
                          "#{value.class}"
                end
                value
            end
        end

        def link_to(parent, name)
            super
            @last_known = parent.last_known.get(name) ||
                          StateLastValueField.new(nil, parent.last_known, name)
            @data_sources = parent.data_sources.get(name) ||
                            StateDataSourceField.new(nil, parent.data_sources, name)
        end

        def attach
            super
            @last_known.attach
            @data_sources.attach
        end

        # Reimplemented from OpenStruct
        def method_missing(name, *args)
            if name =~ /(.*)=$/ && (data_source = data_sources.get($1))
                raise ArgumentError,
                      "cannot explicitely set a field for which a data source exists"
            end
            super
        end

        # Reimplemented from OpenStruct
        #
        # It disables automatic substruct creation for state variables for which
        # a data source exists
        def __get(name, create_substruct = true)
            if (source = data_sources.get(name)) &&
               !source.kind_of?(StateDataSourceField)
                # Don't create a substruct, we know that this subfield should be
                # populated by the data source
                create_substruct = false
            end
            super(name, create_substruct)
        end

        # Read each subfield that have a source, and update both their
        # last_known and current value.
        def read
            data_sources.each_member do |field_name, field_source|
                new_value = field_source.read
                set(field_name, new_value)
                if new_value
                    last_known.set(field_name, new_value)
                end
            end
        end

        def create_model
            StateModel.new
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
            super(model)
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
            @exported_fields.merge names.map(&:to_s).to_set
        end

        def create_subfield(name)
            model = self.model&.get(name)
            StateField.new(model, self, name)
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

        def testing?
            Roby.app.testing?
        end

        def simulation?
            Roby.app.simulation?
        end
    end
end
