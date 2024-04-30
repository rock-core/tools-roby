# frozen_string_literal: true

require "roby/test/self"
require "roby/app/cucumber/helpers"

module Roby
    module App
        describe CucumberHelpers do
            describe ".parse_argument_text_to_hash" do
                it "parses a simple comma-separated sequence" do
                    assert_equal Hash[x: "a", y: "b", z: "c"],
                                 CucumberHelpers.parse_argument_text_to_hash("x=a, y=b, z=c")
                end
                it "parses a 'and' separator at the end" do
                    assert_equal Hash[x: "a", y: "b", z: "c"],
                                 CucumberHelpers.parse_argument_text_to_hash("x=a, y=b and z=c")
                end
                it "parses a hash construct that ends at the end of the stream" do
                    assert_equal Hash[x: Hash[y: "z"]],
                                 CucumberHelpers.parse_argument_text_to_hash("x={y=z}")
                end
                it "raises InvalidSyntax if the first token is not key=value" do
                    assert_raises(CucumberHelpers::InvalidSyntax) do
                        CucumberHelpers.parse_argument_text_to_hash("20")
                    end
                end
                it "raises InvalidSyntax if a token in the middle is not key=value" do
                    assert_raises(CucumberHelpers::InvalidSyntax) do
                        CucumberHelpers.parse_argument_text_to_hash("x=10, 20")
                    end
                end
                it "raises InvalidSyntax if a hash construct is not closed at the end of the string" do
                    assert_raises(CucumberHelpers::InvalidSyntax) do
                        CucumberHelpers.parse_argument_text_to_hash("x={y=z")
                    end
                end
                it "raises InvalidSyntax if a hash construct is not followed by a comma or a and" do
                    assert_raises(CucumberHelpers::InvalidSyntax) do
                        CucumberHelpers.parse_argument_text_to_hash("x={y=z} x=20")
                    end
                end
                it "raises InvalidSyntax if there are too many hash closing markers" do
                    assert_raises(CucumberHelpers::InvalidSyntax) do
                        CucumberHelpers.parse_argument_text_to_hash("x={y=z}}")
                    end
                end
                it "parses a hash value" do
                    assert_equal Hash[x: Hash[a: "x", b: "y"], y: "b", z: "c"],
                                 CucumberHelpers.parse_argument_text_to_hash("x={a=x and b=y}, y=b and z=c")
                end
                it "parses hash values recursively" do
                    assert_equal Hash[x: Hash[a: "x", b: Hash[j: "i"]], y: "b", z: "c"],
                                 CucumberHelpers.parse_argument_text_to_hash("x={a=x and b={j=i}}, y=b and z=c")
                end
            end

            describe ".parse_arguments" do
                it "parses a sequence with comma and 'and' statements" do
                    assert_equal Hash[x: "a", y: "b", z: "c"],
                                 CucumberHelpers.parse_arguments("x=a, y=b and z=c", strict: false)
                end
                it "parses a single value" do
                    assert_equal Hash[x: "a"],
                                 CucumberHelpers.parse_arguments("x=a", strict: false)
                end
                it "parses two values combined with 'and'" do
                    assert_equal Hash[x: "a", y: "b"],
                                 CucumberHelpers.parse_arguments("x=a and y=b", strict: false)
                end
                it "parses two values combined with a comma" do
                    assert_equal Hash[x: "a", y: "b"],
                                 CucumberHelpers.parse_arguments("x=a, y=b", strict: false)
                end
                it "parses a positive numerical value with unit" do
                    flexmock(CucumberHelpers).should_receive(:apply_unit)
                                             .with(10, "unit")
                                             .and_return(20)
                    assert_equal Hash[x: 20],
                                 CucumberHelpers.parse_arguments("x=10unit", strict: false)
                end
                it "parses a negative numerical value with unit" do
                    flexmock(CucumberHelpers).should_receive(:apply_unit)
                                             .with(-10, "unit")
                                             .and_return(20)
                    assert_equal Hash[x: 20],
                                 CucumberHelpers.parse_arguments("x=-10unit", strict: false)
                end
                it "parses hashes recursively" do
                    assert_equal Hash[x: Hash[y: 20]],
                                 CucumberHelpers.parse_arguments("x={y=20m}", strict: false)
                end
                it "converts a floating-point value into a float" do
                    assert_equal Hash[x: 0.1],
                                 CucumberHelpers.parse_arguments("x=0.1", strict: false)
                end
                it "converts an integer value into an integer" do
                    assert_equal Hash[x: 2],
                                 CucumberHelpers.parse_arguments("x=2", strict: false)
                end

                describe "unit validation" do
                    it "raises UnexpectedArgument if strict is set and the argument does not have a quantity" do
                        assert_raises(CucumberHelpers::UnexpectedArgument) do
                            CucumberHelpers.parse_arguments("x=20m", Hash[], strict: true)
                        end
                    end
                    it "validates that the unit and the quantity match" do
                        flexmock(CucumberHelpers).should_receive(:validate_unit)
                                                 .with(:x, 20, "m", :angle).once
                        CucumberHelpers.parse_arguments("x=20m", Hash[x: :angle], strict: false)
                    end
                    it "raises InvalidUnit if the value does not have a unit" do
                        e = assert_raises(CucumberHelpers::InvalidUnit) do
                            CucumberHelpers.parse_arguments("x=20", Hash[x: :angle], strict: false)
                        end
                        assert_equal "expected x=20 to be a angle, but it got no unit",
                                     e.message
                    end
                end
            end

            describe ".parse_arguments_respectively" do
                it "uses the first argument's keys as default names for the parsed values" do
                    assert_equal Hash[x: 10, y: 20],
                                 CucumberHelpers.parse_arguments_respectively(%i[x y], "10m and 20m", strict: false)
                end
                it "applies the same value to all keys if a single numerical value is provided" do
                    assert_equal Hash[x: 10, y: 10],
                                 CucumberHelpers.parse_arguments_respectively(%i[x y], "10m", strict: false)
                end
                it "does not allow to mix name and order" do
                    assert_raises(CucumberHelpers::MixingOrderAndNames) do
                        CucumberHelpers.parse_arguments_respectively(%i[x y], "y=10m and 20m", strict: false)
                    end
                    assert_raises(CucumberHelpers::MixingOrderAndNames) do
                        CucumberHelpers.parse_arguments_respectively(%i[x y], "10m and x=20m", strict: false)
                    end
                end
                it "allows to pass the arguments by name" do
                    assert_equal Hash[y: 10, x: 20],
                                 CucumberHelpers.parse_arguments_respectively(%i[x y], "y=10m and x=20m", strict: false)
                end
                it "raises if names not present in the reference hash are given" do
                    exception = assert_raises(CucumberHelpers::UnexpectedArgument) do
                        CucumberHelpers.parse_arguments_respectively(%i[x y], "z=10m", strict: false)
                    end
                    assert_equal "got 'z' but was expecting one of x, y",
                                 exception.message
                    exception = assert_raises(CucumberHelpers::UnexpectedArgument) do
                        CucumberHelpers.parse_arguments_respectively(%i[x y], "x=10m, y=10m and z=10m", strict: false)
                    end
                    assert_equal "got 'z' but was expecting one of x, y",
                                 exception.message
                end
                it "raises if names present in the reference hash are not given" do
                    exception = assert_raises(CucumberHelpers::MissingArgument) do
                        CucumberHelpers.parse_arguments_respectively(%i[x y], "x=10m", strict: false)
                    end
                    assert_equal "missing 1 argument(s) (for y)",
                                 exception.message
                end
                it "raises if given too many implicit arguments" do
                    exception = assert_raises(CucumberHelpers::UnexpectedArgument) do
                        CucumberHelpers.parse_arguments_respectively(%i[x y], "10m, 20m and 0deg", strict: false)
                    end
                    assert_equal "too many implicit values given, expected 2 (x, y)",
                                 exception.message
                end

                describe "unit validation" do
                    describe "fully implicit mode" do
                        it "raises UnexpectedArgument if strict is set and the argument does not have a quantity" do
                            assert_raises(CucumberHelpers::UnexpectedArgument) do
                                CucumberHelpers.parse_arguments_respectively(%i[x y], "20m", Hash[x: :length], strict: true)
                            end
                        end
                        it "validates that the unit and the quantity match" do
                            flexmock(CucumberHelpers).should_receive(:validate_unit)
                                                     .with(:x, 20.0, "m", :length).once
                            flexmock(CucumberHelpers).should_receive(:validate_unit)
                                                     .with(:y, 20.0, "m", :angle).once
                            CucumberHelpers.parse_arguments_respectively(%i[x y], "20m", Hash[x: :length, y: :angle], strict: false)
                        end
                        it "raises InvalidUnit if the value does not have a unit" do
                            e = assert_raises(CucumberHelpers::InvalidUnit) do
                                CucumberHelpers.parse_arguments_respectively(%i[x y], "20", Hash[x: :length, y: :length], strict: false)
                            end
                            assert_equal "expected x=20 to be a length, but it got no unit",
                                         e.message
                        end
                        it "raises InvalidUnit if the value is not numeric" do
                            e = assert_raises(CucumberHelpers::InvalidUnit) do
                                CucumberHelpers.parse_arguments_respectively(%i[x y], "not numeric", Hash[x: :length, y: :length], strict: false)
                            end
                            assert_equal "expected x=not numeric to be a length, but it is not even a number",
                                         e.message
                        end
                    end

                    describe "name-based mode" do
                        it "raises UnexpectedArgument if strict is set and the argument does not have a quantity" do
                            assert_raises(CucumberHelpers::UnexpectedArgument) do
                                CucumberHelpers.parse_arguments_respectively(%i[x y], "x=20m and y=5m", Hash[x: :length], strict: true)
                            end
                        end
                        it "validates that the unit and the quantity match" do
                            flexmock(CucumberHelpers).should_receive(:validate_unit)
                                                     .with("y", 20.0, "m", :angle).once
                            flexmock(CucumberHelpers).should_receive(:validate_unit)
                                                     .with("x", 5.0, "m", :length).once
                            CucumberHelpers.parse_arguments_respectively(%i[x y], "y=20m and x=5m", Hash[x: :length, y: :angle], strict: false)
                        end
                        it "raises InvalidUnit if the value does not have a unit" do
                            e = assert_raises(CucumberHelpers::InvalidUnit) do
                                CucumberHelpers.parse_arguments_respectively(%i[x y], "x=20m and y=5", Hash[x: :length, y: :length], strict: false)
                            end
                            assert_equal "expected y=5 to be a length",
                                         e.message
                        end
                    end

                    describe "order-based mode" do
                        it "raises UnexpectedArgument if strict is set and the argument does not have a quantity" do
                            assert_raises(CucumberHelpers::UnexpectedArgument) do
                                CucumberHelpers.parse_arguments_respectively(%i[x y], "20m and 5m", Hash[x: :length], strict: true)
                            end
                        end
                        it "raises InvalidUnit if the unit does not match the expected quantity" do
                            flexmock(CucumberHelpers).should_receive(:validate_unit)
                                                     .with(:y, 5.0, "m", :angle).once
                            flexmock(CucumberHelpers).should_receive(:validate_unit)
                                                     .with(:x, 20.0, "m", :length).once
                            CucumberHelpers.parse_arguments_respectively(%i[x y], "20m and 5m", Hash[x: :length, y: :angle], strict: false)
                        end
                        it "raises InvalidUnit if the value does not have a unit" do
                            e = assert_raises(CucumberHelpers::InvalidUnit) do
                                CucumberHelpers.parse_arguments_respectively(%i[x y], "20m and 5", Hash[x: :length, y: :length], strict: false)
                            end
                            assert_equal "expected y=5 to be a length",
                                         e.message
                        end
                    end
                end
            end

            describe ".try_numerical_with_unit" do
                it "allows to skip a leading zero" do
                    assert_equal [-0.2, "unit"], CucumberHelpers.try_numerical_value_with_unit("-.2unit")
                    assert_equal [0.2, "unit"], CucumberHelpers.try_numerical_value_with_unit(".2unit")
                end
                it "extracts the unit and value from a negative float" do
                    assert_equal [-10.2, "unit"], CucumberHelpers.try_numerical_value_with_unit("-10.2unit")
                end
                it "extracts the unit and value from a positive float" do
                    assert_equal [10.2, "unit"], CucumberHelpers.try_numerical_value_with_unit("10.2unit")
                end
                it "extracts the unit and value from a negative integer" do
                    assert_equal [-10, "unit"], CucumberHelpers.try_numerical_value_with_unit("-10unit")
                end
                it "extracts the unit and value from a positive integer" do
                    assert_equal [10, "unit"], CucumberHelpers.try_numerical_value_with_unit("10unit")
                end
                it "returns nil from an invalid value" do
                    assert_nil CucumberHelpers.try_numerical_value_with_unit("a10.2unit")
                end
                it "returns nil from an integer without unit" do
                    assert_nil CucumberHelpers.try_numerical_value_with_unit("10")
                end
                it "returns nil from a float value without unit" do
                    assert_nil CucumberHelpers.try_numerical_value_with_unit("10.1")
                end
            end

            describe ".apply_unit" do
                it "converts degrees to radians" do
                    assert_equal (10 * Math::PI / 180),
                                 CucumberHelpers.apply_unit(10, "deg")
                end
                it "leaves meters as-is" do
                    assert_equal 10,
                                 CucumberHelpers.apply_unit(10, "m")
                end
                it "converts minutes to seconds" do
                    assert_equal 600, CucumberHelpers.apply_unit(10, "min")
                end
                it "converts hours to seconds" do
                    assert_equal 3600, CucumberHelpers.apply_unit(1, "h")
                end
                it "leaves seconds as-is" do
                    assert_equal 1, CucumberHelpers.apply_unit(1, "s")
                end
                it "raises for any other unit" do
                    assert_raises(CucumberHelpers::InvalidUnit) do
                        CucumberHelpers.apply_unit(10, "unknown")
                    end
                end
            end

            describe ".validate_unit" do
                it "passes if a length is specified in 'm'" do
                    CucumberHelpers.validate_unit(:x, 20, "m", :length)
                end
                it "raises if a length is not specified in 'm'" do
                    e = assert_raises(CucumberHelpers::InvalidUnit) do
                        CucumberHelpers.validate_unit(:x, 20, "foo", :length)
                    end
                    assert_equal "expected a length in place of x=20foo", e.message
                end

                it "passes if an angle is specified in 'deg'" do
                    CucumberHelpers.validate_unit(:x, 20, "deg", :angle)
                end
                it "raises if an angle is not specified in 'deg'" do
                    e = assert_raises(CucumberHelpers::InvalidUnit) do
                        CucumberHelpers.validate_unit(:x, 20, "m", :angle)
                    end
                    assert_equal "expected a angle in place of x=20m", e.message
                end

                it "passes if a time is specified in 'h'" do
                    CucumberHelpers.validate_unit(:x, 20, "h", :time)
                end
                it "passes if a time is specified in 'min'" do
                    CucumberHelpers.validate_unit(:x, 20, "min", :time)
                end
                it "passes if a time is specified in 's'" do
                    CucumberHelpers.validate_unit(:x, 20, "s", :time)
                end
                it "raises if an angle is not specified in h, min or s" do
                    e = assert_raises(CucumberHelpers::InvalidUnit) do
                        CucumberHelpers.validate_unit(:x, 20, "m", :time)
                    end
                    assert_equal "expected a time in place of x=20m", e.message
                end

                it "raises ArgumentError if the quantity is unknown" do
                    e = assert_raises(ArgumentError) do
                        CucumberHelpers.validate_unit(:x, 20, "m", :unknown)
                    end
                    assert_equal "unknown quantity definition 'unknown', "\
                                 "expected one of :length, :angle, :time",
                                 e.message
                end
            end

            describe ".parse_numerical_value" do
                it "returns a pure numerical value as-is" do
                    assert_equal 10, CucumberHelpers.parse_numerical_value("10")
                end
                it "applies a unit if present" do
                    flexmock(CucumberHelpers).should_receive(:apply_unit).with(1, "deg")
                                             .and_return(ret = flexmock)
                    assert_equal [ret, "deg"], CucumberHelpers.parse_numerical_value("1deg")
                end
                it "raises ArgumentError if the string is not a numerical value, with or without a unit" do
                    assert_raises(ArgumentError) do
                        CucumberHelpers.parse_numerical_value("bla")
                    end
                end
            end
        end
    end
end
