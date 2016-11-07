module Roby
    module App
        # Module with helpers to be used in cucumber specifications
        module CucumberHelpers
            # Exception raised when a unit that cannot be interpreted is
            # encountered
            class InvalidUnit < ArgumentError; end

            # Exception raised when two arguments should have the same set of
            # names but one has a name that the reference does not
            class MissingArgument < ArgumentError; end

            # Exception raised when two arguments should have the same set of
            # names but one has a name that the reference does not
            class UnexpectedArgument < ArgumentError; end

            # Exception raised by {.parse_arguments_respectively} when one uses
            # the explicit and implicit syntaxes at the same time
            class MixingOrderAndNames < ArgumentError; end

            # Parsing of a set of quantities, in the form
            #
            #   x=VAL, y=VAL and z=VAL
            #
            # The value can be specified as a numerical value with unit, in
            # which case the value is converted into the corresponding SI unit,
            # as e.g.
            #
            #   yaw=10deg
            #
            # will be converted to
            #
            #   Hash[yaw: 0.1745] # 10 degrees in radians
            def self.parse_arguments(raw_arguments)
                arguments = Hash.new
                raw_arguments.split(/(?:, | and )/).
                    each do |arg|
                        arg_name, arg_value = arg.split('=')
                        if value_with_unit = try_numerical_value_with_unit(arg_value)
                            arg_value = apply_unit(*value_with_unit)
                        end
                        arguments[arg_name.to_sym] = arg_value
                    end
                arguments
            end

            # Parsing of a set of quantities that follow another already given
            # set
            #
            # @example pose with tolerance
            #   the pose x=10m and y=20m with tolerance 1m and 1m
            #
            def self.parse_arguments_respectively(reference, raw_arguments)
                arguments = Hash.new
                has_implicit, has_explicit = false, false
                raw_arguments.split(/(?:, | and )/).
                    each_with_index do |arg, arg_i|
                        arg_name, arg_value = arg.split('=')
                        if arg_value
                            if has_implicit
                                raise MixingOrderAndNames, "cannot mix order-based syntax and explicit names"
                            end
                            has_explicit = true
                        else
                            if has_explicit
                                raise MixingOrderAndNames, "cannot mix order-based syntax and explicit names"
                            end
                            arg_name, arg_value = reference[arg_i], arg_name
                            has_implicit = true
                        end
                        if value_with_unit = try_numerical_value_with_unit(arg_value)
                            arg_value = apply_unit(*value_with_unit)
                        end
                        if !reference.include?(arg_name.to_sym)
                            raise UnexpectedArgument, "got '#{arg_name}' but was expecting one of #{reference.map(&:to_s).sort.join(", ")}"
                        end
                        arguments[arg_name.to_sym] = arg_value
                    end

                if arguments.keys.to_set != reference.to_set
                    missing = reference.to_set - arguments.keys
                    raise MissingArgument, "missing #{missing.size} argument(s) (for #{missing.map(&:to_s).sort.join(", ")})"
                end
                arguments
            end

            # @api private
            #
            # Helper that identifies a value which looks like a numerical value
            # with unit and returns it as (numeric, unit)
            #
            # @return [(Numeric,String),nil]
            def self.try_numerical_value_with_unit(string)
                if string =~ /^(-?\d+(?:\.\d+)?)([^\d]\w*)$/
                    return Float($1), $2
                end
            end

            # @api private
            #
            # Helper that converts a value with unit into the corresponding
            # normalized value (e.g. degrees to radians)
            #
            # @raise InvalidUnit if the unit parameter is unknown
            def self.apply_unit(value, unit)
                if unit == 'deg'
                    value * Math::PI / 180
                elsif unit == 'm'
                    value
                elsif unit == 'h'
                    value * 3600
                elsif unit == 'min'
                    value * 60
                elsif unit == 's'
                    value
                else
                    raise InvalidUnit, "unknown unit #{unit}, known units are deg, m (meters), h (hour), min (minute) and s (seconds)"
                end
            end
        end
    end
end

