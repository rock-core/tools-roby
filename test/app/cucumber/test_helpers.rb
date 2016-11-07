require 'roby/test/self'
require 'roby/app/cucumber/helpers'

module Roby
    module App
        describe CucumberHelpers do
            describe ".parse_arguments" do
                it "parses a sequence with comma and 'and' statements" do
                    assert_equal Hash[x: 'a', y: 'b', z: 'c'],
                        CucumberHelpers.parse_arguments("x=a, y=b and z=c")
                end
                it "parses a single value" do
                    assert_equal Hash[x: 'a'],
                        CucumberHelpers.parse_arguments("x=a")
                end
                it "parses two values combined with 'and'" do
                    assert_equal Hash[x: 'a', y: 'b'],
                        CucumberHelpers.parse_arguments("x=a and y=b")
                end
                it "parses two values combined with a comma" do
                    assert_equal Hash[x: 'a', y: 'b'],
                        CucumberHelpers.parse_arguments("x=a, y=b")
                end

                it "parses a positive numerical value with unit" do
                    flexmock(CucumberHelpers).should_receive(:apply_unit).
                        with(10, 'unit').
                        and_return(20)
                    assert_equal Hash[x: 20],
                        CucumberHelpers.parse_arguments("x=10unit")
                end
                it "parses a negative numerical value with unit" do
                    flexmock(CucumberHelpers).should_receive(:apply_unit).
                        with(-10, 'unit').
                        and_return(20)
                    assert_equal Hash[x: 20],
                        CucumberHelpers.parse_arguments("x=-10unit")
                end
            end

            describe ".parse_arguments_respectively" do
                it "uses the first argument's keys as default names for the parsed values" do
                    assert_equal Hash[x: 10, y: 20],
                        CucumberHelpers.parse_arguments_respectively([:x, :y], "10m and 20m")
                end
                it "does not allow to mix name and order" do
                    assert_raises(CucumberHelpers::MixingOrderAndNames) do
                        CucumberHelpers.parse_arguments_respectively([:x, :y], "y=10m and 20m")
                    end
                    assert_raises(CucumberHelpers::MixingOrderAndNames) do
                        CucumberHelpers.parse_arguments_respectively([:x, :y], "10m and x=20m")
                    end
                end
                it "allows to pass the arguments by name" do
                    assert_equal Hash[y: 10, x: 20],
                        CucumberHelpers.parse_arguments_respectively([:x, :y], "y=10m and x=20m")
                end
                it "raises if names not present in the reference hash are given" do
                    exception = assert_raises(CucumberHelpers::UnexpectedArgument) do
                        CucumberHelpers.parse_arguments_respectively([:x, :y], "z=10m")
                    end
                    assert_equal "got 'z' but was expecting one of x, y",
                        exception.message
                    exception = assert_raises(CucumberHelpers::UnexpectedArgument) do
                        CucumberHelpers.parse_arguments_respectively([:x, :y], "x=10m, y=10m and z=10m")
                    end
                    assert_equal "got 'z' but was expecting one of x, y",
                        exception.message
                end
                it "raises if names present in the reference hash are not given" do
                    exception = assert_raises(CucumberHelpers::MissingArgument) do
                        CucumberHelpers.parse_arguments_respectively([:x, :y], "x=10m")
                    end
                    assert_equal "missing 1 argument(s) (for y)",
                        exception.message
                end
            end

            describe ".try_numerical_with_unit" do
                it "extracts the unit and value from a negative float" do
                    assert_equal [-10.2, 'unit'], CucumberHelpers.try_numerical_value_with_unit("-10.2unit")
                end
                it "extracts the unit and value from a positive float" do
                    assert_equal [10.2, 'unit'], CucumberHelpers.try_numerical_value_with_unit("10.2unit")
                end
                it "extracts the unit and value from a negative integer" do
                    assert_equal [-10, 'unit'], CucumberHelpers.try_numerical_value_with_unit("-10unit")
                end
                it "extracts the unit and value from a positive integer" do
                    assert_equal [10, 'unit'], CucumberHelpers.try_numerical_value_with_unit("10unit")
                end
                it "returns nil from an invalid value" do
                    assert_nil CucumberHelpers.try_numerical_value_with_unit("a10.2unit")
                end
                it "returns nil from a numerical value without unit" do
                    assert_nil CucumberHelpers.try_numerical_value_with_unit("10")
                end
            end

            describe ".apply_unit" do
                it "converts degrees to radians" do
                    assert_equal (10 * Math::PI / 180),
                        CucumberHelpers.apply_unit(10, 'deg')
                end
                it "leaves meters as-is" do
                    assert_equal 10,
                        CucumberHelpers.apply_unit(10, 'm')
                end
                it "converts minutes to seconds" do
                    assert_equal 600, CucumberHelpers.apply_unit(10, 'min')
                end
                it "converts hours to seconds" do
                    assert_equal 3600, CucumberHelpers.apply_unit(1, 'h')
                end
                it "leaves seconds as-is" do
                    assert_equal 1, CucumberHelpers.apply_unit(1, 's')
                end
                it "raises for any other unit" do
                    assert_raises(CucumberHelpers::InvalidUnit) do
                        CucumberHelpers.apply_unit(10, 'unknown')
                    end
                end
            end
        end
    end
end

