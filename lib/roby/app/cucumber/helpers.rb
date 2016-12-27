require 'utilrb/hash/map_value'

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
            def self.parse_arguments(raw_arguments, expected = Hash.new, strict: true)
                hash = parse_argument_text_to_hash(raw_arguments)
                parse_hash_numerical_values(hash, expected, strict: strict)
            end

            def self.parse_hash_numerical_values(hash, expected = Hash.new, strict: true)
                hash.map_value do |key, value|
                    expected_quantity = expected[key]
                    if strict && !expected_quantity
                        raise UnexpectedArgument, "unexpected argument found #{key}"
                    elsif value.kind_of?(Hash)
                        parse_hash_numerical_values(value, expected_quantity || Hash.new, strict: strict)
                    elsif value_with_unit = try_numerical_value_with_unit(value)
                        if expected_quantity
                            validate_unit(key, *value_with_unit, expected_quantity)
                        end
                        apply_unit(*value_with_unit)
                    elsif expected_quantity
                        raise InvalidUnit, "expected #{key}=#{value} to be a #{expected_quantity}, but it got no unit"
                    else value
                    end
                end
            end

            class UnexpectedArgument < ArgumentError; end
            class InvalidSyntax < ArgumentError; end

            def self.validate_unit(name, value, unit, quantity)
                if quantity == :length
                    if unit != 'm'
                        raise InvalidUnit, "expected a length in place of #{name}=#{value}#{unit}"
                    end
                elsif quantity == :angle
                    if unit != 'deg'
                        raise InvalidUnit, "expected an angle in place of #{name}=#{value}#{unit}"
                    end
                elsif quantity == :time
                    if !%w{h min s}.include?(unit)
                        raise InvalidUnit, "expected a time in place of #{name}=#{value}#{unit}"
                    end
                else raise ArgumentError, "unknown quantity definition '#{quantity}', expected one of :length, :angle or :time"
                end
            end

            def self.parse_argument_text_to_hash(raw_arguments)
                current = Hash.new
                stack   = Array.new
                scanner = StringScanner.new(raw_arguments)
                while !scanner.eos?
                    arg_name = scanner.scan_until(/=/)
                    if !arg_name
                        raise InvalidSyntax, "expected to find '=' in #{raw_arguments}\n#{" " * (24 + scanner.pos)}^"
                    end
                    arg_name = arg_name[0, arg_name.size - 1].to_sym

                    if scanner.peek(1) == '{'
                        scanner.getch
                        stack << current
                        current[arg_name] = (child = Hash.new)
                        current = child
                    else
                        match = scanner.scan_until(/(\s*,\s*|\s+and\s+|\s*}\s*)/)
                        if match && (scanner[1].strip == '}')
                            current[arg_name] = match[0, match.size - scanner[1].size]

                            begin
                                current = stack.pop
                                if !current
                                    raise InvalidSyntax, "unbalanced closed hash"
                                end
                            end while scanner.scan(/\s*}\s*/)

                            if !scanner.eos? && !scanner.scan(/\s*,\s*|\s+and\s+/)
                                raise InvalidSyntax, "expected comma or 'and' after }"
                            end
                        elsif match
                            current[arg_name] = match[0, match.size - scanner[1].size]
                        else
                            current[arg_name] = scanner.rest
                            scanner.terminate
                        end
                    end
                end
                if !stack.empty?
                    raise InvalidSyntax, "expected closing } at the end of string"
                end
                current
            end

            # Parsing of a set of quantities that follow another already given
            # set
            #
            # @example pose with tolerance
            #   the pose x=10m and y=20m with tolerance 1m and 1m
            #
            def self.parse_arguments_respectively(reference, raw_arguments, expected = Hash.new, strict: true)
                arguments = Hash.new
                has_implicit, has_explicit = false, false
                raw_arguments = raw_arguments.split(/(?:, | and )/)

                # Same value for all keys
                if raw_arguments.size == 1 && (raw_arguments.first !~ /=/)
                    arg_value = raw_arguments.first

                    if strict
                        reference.each do |key|
                            if !expected[key]
                                raise UnexpectedArgument, "unexpected argument found #{key}"
                            end
                        end
                    end

                    if value_with_unit = try_numerical_value_with_unit(arg_value)
                        reference.each do |key|
                            if expectation = expected[key]
                                validate_unit(key, *value_with_unit, expectation)
                            end
                        end
                        arg_value = apply_unit(*value_with_unit)
                    else
                        reference.each do |key|
                            is_numeric = Float(arg_value) rescue nil
                            if is_numeric && (expectation = expected[key])
                                raise InvalidUnit, "expected #{key}=#{arg_value} to be a #{expectation}"
                            end
                        end
                    end
                    reference.each do |key|
                        arguments[key] = arg_value
                    end
                    return arguments
                end

                raw_arguments.each_with_index do |arg, arg_i|
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

                    expected_quantity = expected[arg_name.to_sym]
                    if strict && !expected_quantity
                        raise UnexpectedArgument, "unexpected argument found #{arg_name}"
                    elsif value_with_unit = try_numerical_value_with_unit(arg_value)
                        if expected_quantity
                            validate_unit(arg_name, *value_with_unit, expected_quantity)
                        end
                        arg_value = apply_unit(*value_with_unit)
                    elsif expected_quantity
                        raise InvalidUnit, "expected #{arg_name}=#{arg_value} to be a #{expected_quantity}"
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

            # Parses a numerical value, possibly with a unit, in which case it
            # is converted to the corresponding "natural" unit (e.g. meters,
            # seconds, ...)
            #
            # @return [(Float,String)] the normalized value and the unit
            def self.parse_numerical_value(text, expected_quantity = nil)
                value, unit = try_numerical_value_with_unit(text)
                if unit
                    if expected_quantity
                        validate_unit(nil, value, unit, expected_quantity)
                    end
                    return apply_unit(value, unit), unit
                elsif expected_quantity
                    raise InvalidUnit, "expected a #{expected_quantity}, but got #{text}"
                else
                    Float(text)
                end
            end

            # @api private
            #
            # Helper that identifies a value which looks like a numerical value
            # with unit and returns it as (numeric, unit)
            #
            # @return [(Numeric,String),nil]
            def self.try_numerical_value_with_unit(string)
                if string =~ /^(-?\.\d+|-?\d+(?:\.\d+)?)([^\d]\w*)$/
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

