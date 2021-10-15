# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Models
        describe TaskServiceModel do
            attr_reader :tag

            before do
                @tag = TaskService.new_submodel
            end

            it "creates submodels of itself with #new_submodel" do
                subtag = tag.new_submodel
                assert subtag.fullfills?(tag)
            end

            it "declares supermodels of itself with #provides" do
                subtag = TaskService.new_submodel
                subtag.provides tag
                assert subtag.fullfills?(tag)
            end

            describe "arguments" do
                before do
                    tag.argument :model_tag_1
                end

                it "holds argument definitions" do
                    assert tag.has_argument?(:model_tag_1)
                end
                it "has the arguments of its supermodel" do
                    subtag = tag.new_submodel { argument :model_tag_2 }
                    assert subtag.has_argument?(:model_tag_1)
                    assert subtag.has_argument?(:model_tag_2)
                end
            end
        end
    end
end
