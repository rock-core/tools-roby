module Roby
    class StateModelField
        include ExtendedStruct

        def initialize
            initialize_extended_struct(StateModelField)
            global_filter do |name, value|
                StateModel.validate_state_model_field(name, value)
            end
        end
    end

    class StateModel < BasicObject
        include ExtendedStruct
        extend ExtendedStruct
        initialize_extended_struct(StateModelField)

        def self.validate_state_model_field(name, value)
            if value.kind_of?(StateModelField)
                value
            elsif value.respond_to?(:to_state_model_field)
                value.to_state_model_field
            else
                raise ArgumentError, "cannot set #{value} on #{name} in a state model. Only allowed values are StateModelField instances and values that respond to #to_state_model_field"
            end
        end

	def initialize
            initialize_extended_struct(StateModel)
            global_filter do |name, value|
                StateModel.validate_state_model_field(name, value)
            end

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
	    @exported_fields = exported_fiels
	end

	def testing?; Roby.app.testing? end
	def simulation?; Roby.app.simulation? end
    end
    StateSpace = StateModel
end
