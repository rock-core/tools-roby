require 'roby/test/self'

module Roby
    module DRoby
        module V5
            class DRobyConstantTestObject
                extend DRobyConstant::Dump
            end

            class DRobyConstantAbsoluteResolutionTest
                extend DRobyConstant::Dump
                module Roby
                    module DRoby
                        module V5
                            DRobyConstantAbsoluteResolutionTest = 'invalid'
                        end
                    end
                end
            end

            describe DRobyConstant do
                it "dumps and resolves a class by name" do
                    marshalled = DRobyConstantTestObject.droby_dump(flexmock)
                    assert_equal "::Roby::DRoby::V5::DRobyConstantTestObject", marshalled.name
                    assert_same DRobyConstantTestObject, marshalled.proxy(flexmock)
                end

                it "caches whether a constant can be properly resolved" do
                    marshalled = DRobyConstantTestObject.droby_dump(flexmock)
                    flexmock(DRobyConstantTestObject).should_receive(:constant).never
                    assert_same marshalled, DRobyConstantTestObject.droby_dump(flexmock)
                end

                it "raises if the constant resolves to another object" do
                    obj = flexmock(name: "Roby::DRoby")
                    obj.singleton_class.include DRobyConstant::Dump
                    e = assert_raises(DRobyConstant::Dump::MismatchingLocalConstant) do
                        obj.droby_dump(flexmock)
                    end
                    assert_equal "got DRobyConstant whose name '::Roby::DRoby' resolves to Roby::DRoby(Module), not itself (#{obj})", e.message
                end

                it "resolves the constant name as an absolute name" do
                    marshalled = DRobyConstantAbsoluteResolutionTest.droby_dump(flexmock)
                    assert_equal "::Roby::DRoby::V5::DRobyConstantAbsoluteResolutionTest", marshalled.name
                    assert_same DRobyConstantAbsoluteResolutionTest, marshalled.proxy(flexmock)
                end

                it "raises on dump if the object's name cannot be resolved" do
                    obj = flexmock(name: "Does::Not::Exist")
                    obj.singleton_class.include DRobyConstant::Dump
                    messages = capture_log(Roby, :warn) do
                        e = assert_raises(DRobyConstant::Dump::ConstantResolutionFailed) do
                            obj.droby_dump(flexmock)
                        end
                        assert_equal "cannot resolve constant name for #{obj}", e.message
                    end
                    assert_equal ["could not resolve constant name for #{obj}",
                                  "uninitialized constant Does (NameError)"], messages
                end

                it "raises on dump if the object's name is not a valid constant name" do
                    obj = flexmock(name: "0_does.not_exist")
                    obj.singleton_class.include DRobyConstant::Dump
                    messages = capture_log(Roby, :warn) do
                        e = assert_raises(DRobyConstant::Dump::ConstantResolutionFailed) do
                            obj.droby_dump(flexmock)
                        end
                        assert_equal "cannot resolve constant name for #{obj}", e.message
                    end
                    assert_equal ["could not resolve constant name for #{obj}",
                                  "wrong constant name 0_does.not_exist (NameError)"], messages
                end
            end
        end
    end
end

