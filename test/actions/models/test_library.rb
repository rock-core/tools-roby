require 'roby/test/self'

module Roby
    module Actions
        module Models
            describe Library do
                it "allows to define actions" do
                    library = Actions::Library.new_submodel do
                        describe 'test'
                        def action_test
                        end
                    end
                    assert library.find_action_by_name('action_test')
                end

                describe "#use_library" do
                    attr_reader :library
                    before do
                        @library = Actions::Library.new_submodel do
                            describe 'test'
                            def action_test
                            end
                        end
                    end

                    it "imports the actions of the used library" do
                        target = Actions::Library.new_submodel
                        target.use_library library
                        assert target.find_action_by_name('action_test')
                    end

                    it "does not propagate its own modifications to the used library" do
                        target = Actions::Library.new_submodel
                        target.use_library library
                        target.class_eval do
                            describe 'test'
                            def target_action
                            end
                        end
                        refute library.find_action_by_name('target_action')
                        assert target.find_action_by_name('target_action')
                    end
                end
            end
        end
    end
end

