# frozen_string_literal: true

require "roby/test/self"
require "roby/test/spec"
require "roby/interface/rest/test"
require "roby/interface/rest/task"

module Roby
    module Interface
        module REST
            class RESTTestHelperTest < Roby::Test::Spec
                include Test

                def rest_api
                    Class.new(Grape::API) do
                        format :json

                        mount API
                        helpers Helpers

                        get "/test" do
                            roby_execute { roby_plan.num_tasks }
                        end

                        get "/storage_value" do
                            roby_storage["write"] = 21
                            roby_storage["read"]
                        end
                    end
                end

                it "allows to execute a test that synchronizes with the engine" do
                    assert_equal 0, JSON.parse(get("/test").body)
                end

                it "gives access to the same roby_storage object that is used "\
                   "by the API itself" do
                    roby_storage["read"] = 42
                    assert_equal 42, JSON.parse(get("/storage_value").body)
                    assert_equal 21, roby_storage["write"]
                end
            end
        end
    end
end
